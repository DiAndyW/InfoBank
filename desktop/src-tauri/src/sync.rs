use std::sync::Mutex;
use std::time::Duration;

use chrono::{DateTime, Utc};
use rusqlite::Connection;
use serde::Deserialize;

pub const POLL_INTERVAL: Duration = Duration::from_secs(10);
const MAX_BACKOFF: Duration = Duration::from_secs(300);

#[derive(Debug, PartialEq)]
pub enum SyncError {
    NotConfigured,
    Unauthorized,
    Failed(String),
}

#[derive(Deserialize)]
pub struct Page {
    items: Vec<PulledItem>,
    topics: Vec<PulledTopic>,
    tombstones: Vec<String>,
    cursor: i64,
    has_more: bool,
}

#[derive(Deserialize)]
struct PulledItem {
    id: String,
    topic_id: Option<String>,
    text: Option<String>,
    capture_time: DateTime<Utc>,
    deleted_at: Option<DateTime<Utc>>,
    purge_at: Option<DateTime<Utc>>,
    attachments: Vec<PulledAttachment>,
}

#[derive(Deserialize)]
struct PulledAttachment {
    id: String,
    filename: String,
    mime_type: String,
    size_bytes: i64,
    uploaded: bool,
    has_thumbnail: bool,
}

#[derive(Deserialize)]
struct PulledTopic {
    id: String,
    name: String,
    archived_at: Option<DateTime<Utc>>,
    deleted_at: Option<DateTime<Utc>>,
}

fn micros(t: Option<DateTime<Utc>>) -> Option<i64> {
    t.map(|t| t.timestamp_micros())
}

/// Writes one pull page and its cursor in one transaction; true if it held any change.
pub fn apply_pull(conn: &Connection, page: &Page) -> rusqlite::Result<bool> {
    let tx = conn.unchecked_transaction()?;
    for t in &page.topics {
        tx.execute(
            "INSERT INTO topics (id, name, archived_at, deleted_at) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT (id) DO UPDATE SET
                name = excluded.name, archived_at = excluded.archived_at, deleted_at = excluded.deleted_at",
            (&t.id, &t.name, micros(t.archived_at), micros(t.deleted_at)),
        )?;
    }
    for it in &page.items {
        tx.execute(
            "INSERT INTO items (id, topic_id, text, capture_time, deleted_at, purge_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT (id) DO UPDATE SET
                topic_id = excluded.topic_id, text = excluded.text, capture_time = excluded.capture_time,
                deleted_at = excluded.deleted_at, purge_at = excluded.purge_at",
            (&it.id, &it.topic_id, &it.text, it.capture_time.timestamp_micros(), micros(it.deleted_at), micros(it.purge_at)),
        )?;
        // Pull sends the Item's whole live set, so anything missing from it was removed.
        let keep: Vec<&str> = it.attachments.iter().map(|a| a.id.as_str()).collect();
        tx.execute(
            "DELETE FROM attachments WHERE item_id = ?1 AND id NOT IN (SELECT value FROM json_each(?2))",
            (&it.id, serde_json::to_string(&keep).expect("a list of strings serializes")),
        )?;
        for a in &it.attachments {
            tx.execute(
                "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                 ON CONFLICT (id) DO UPDATE SET
                    item_id = excluded.item_id, filename = excluded.filename, mime_type = excluded.mime_type,
                    size_bytes = excluded.size_bytes, uploaded = excluded.uploaded, has_thumbnail = excluded.has_thumbnail",
                (&a.id, &it.id, &a.filename, &a.mime_type, a.size_bytes, a.uploaded, a.has_thumbnail),
            )?;
        }
    }
    for id in &page.tombstones {
        tx.execute("DELETE FROM items WHERE id = ?1", [id])?;
    }
    tx.execute("UPDATE device SET pull_cursor = ?1", [page.cursor])?;
    tx.commit()?;
    Ok(!(page.items.is_empty() && page.topics.is_empty() && page.tombstones.is_empty()))
}

/// The status to show after a cycle and how long to wait before the next; None waits for Settings to be saved.
pub fn outcome(result: &Result<bool, SyncError>, failures: u32) -> (&'static str, Option<Duration>) {
    match result {
        Ok(_) => ("synced", Some(POLL_INTERVAL)),
        Err(SyncError::Failed(_)) => ("offline", Some(Duration::from_secs(2u64.saturating_pow(failures)).min(MAX_BACKOFF))),
        Err(SyncError::Unauthorized) => ("unauthorized", None),
        Err(SyncError::NotConfigured) => ("not_configured", None),
    }
}

const HTTP_TIMEOUT: Duration = Duration::from_secs(30);
// The Server's per-push op limit.
const PUSH_BATCH: i64 = 500;

pub fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        // A redirect must not carry the secret to another host.
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("the HTTP client builds")
}

#[derive(Deserialize)]
struct PushResponse {
    results: Vec<PushResult>,
}

#[derive(Deserialize)]
struct PushResult {
    op_id: String,
    status: String,
    reason: Option<String>,
}

async fn send(req: reqwest::RequestBuilder, token: &str) -> Result<reqwest::Response, SyncError> {
    let res = req.bearer_auth(token).send().await.map_err(|e| SyncError::Failed(e.without_url().to_string()))?;
    match res.status() {
        s if s.is_success() => Ok(res),
        reqwest::StatusCode::UNAUTHORIZED => Err(SyncError::Unauthorized),
        s => Err(SyncError::Failed(format!("the Server answered {s}"))),
    }
}

fn failed(e: impl std::fmt::Display) -> SyncError {
    SyncError::Failed(e.to_string())
}

/// Pushes the whole outbox, then pulls until caught up. True if anything was pushed or pulled.
pub async fn cycle(db: &Mutex<Connection>, secret: &keyring_core::Entry, client: &reqwest::Client) -> Result<bool, SyncError> {
    let (url, device_id): (Option<String>, String) = db
        .lock()
        .unwrap()
        .query_row("SELECT server_url, device_id FROM device", [], |r| Ok((r.get(0)?, r.get(1)?)))
        .map_err(failed)?;
    let url = url.ok_or(SyncError::NotConfigured)?;
    let token = match secret.get_password() {
        Ok(t) => t,
        Err(keyring_core::Error::NoEntry) => return Err(SyncError::NotConfigured),
        Err(e) => return Err(SyncError::Failed(format!("couldn't read the keychain: {e}"))),
    };

    let mut changed = false;
    loop {
        let batch: Vec<(i64, String)> = {
            let conn = db.lock().unwrap();
            let mut stmt = conn.prepare("SELECT seq, op FROM outbox ORDER BY seq LIMIT ?1").map_err(failed)?;
            stmt.query_map([PUSH_BATCH], |r| Ok((r.get(0)?, r.get(1)?)))
                .map_err(failed)?
                .collect::<rusqlite::Result<_>>()
                .map_err(failed)?
        };
        let Some(&(last_seq, _)) = batch.last() else { break };
        let ops: Vec<serde_json::Value> =
            batch.iter().map(|(_, op)| serde_json::from_str(op)).collect::<Result<_, _>>().map_err(failed)?;
        let body = serde_json::json!({"device_id": device_id, "ops": ops});
        let res = send(client.post(format!("{url}/sync/push")).json(&body), &token).await?;
        let res: PushResponse = res.json().await.map_err(failed)?;
        for r in res.results.iter().filter(|r| r.status == "rejected") {
            eprintln!("sync: op {} rejected: {}", r.op_id, r.reason.as_deref().unwrap_or("no reason"));
        }
        // Every op in the batch got an answer, so all of them leave the outbox; pull brings the Server's version.
        db.lock().unwrap().execute("DELETE FROM outbox WHERE seq <= ?1", [last_seq]).map_err(failed)?;
        changed = true;
    }

    loop {
        let cursor: i64 =
            db.lock().unwrap().query_row("SELECT pull_cursor FROM device", [], |r| r.get(0)).map_err(failed)?;
        let res = send(client.get(format!("{url}/sync/pull?cursor={cursor}")), &token).await?;
        let page: Page = res.json().await.map_err(failed)?;
        changed |= apply_pull(&db.lock().unwrap(), &page).map_err(failed)?;
        if !page.has_more {
            return Ok(changed);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        (dir, conn)
    }

    fn page(json: serde_json::Value) -> Page {
        serde_json::from_value(json).unwrap()
    }

    fn attachment(id: &str) -> serde_json::Value {
        serde_json::json!({"id": id, "filename": format!("{id}.png"), "mime_type": "image/png",
                           "size_bytes": 10, "uploaded": true, "has_thumbnail": false})
    }

    fn item(id: &str, text: &str, attachments: Vec<serde_json::Value>) -> serde_json::Value {
        serde_json::json!({"id": id, "topic_id": null, "text": text,
                           "capture_time": "2025-10-09T08:53:20.123456Z",
                           "deleted_at": null, "purge_at": null, "attachments": attachments})
    }

    fn attachment_ids(conn: &Connection) -> Vec<String> {
        let mut stmt = conn.prepare("SELECT id FROM attachments ORDER BY id").unwrap();
        stmt.query_map([], |r| r.get(0)).unwrap().collect::<rusqlite::Result<_>>().unwrap()
    }

    #[test]
    fn a_page_is_stored_and_its_cursor_saved() {
        let (_d, conn) = fresh();
        let p = page(serde_json::json!({
            "items": [item("i", "hello", vec![attachment("a")])],
            "topics": [{"id": "t", "name": "Mosaic", "archived_at": null, "deleted_at": null}],
            "tombstones": [], "cursor": 7, "has_more": false,
        }));
        assert!(apply_pull(&conn, &p).unwrap());

        let (text, time): (String, i64) =
            conn.query_row("SELECT text, capture_time FROM items WHERE id = 'i'", [], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap();
        assert_eq!((text.as_str(), time), ("hello", 1_760_000_000_123_456));
        assert_eq!(attachment_ids(&conn), ["a"]);
        let name: String = conn.query_row("SELECT name FROM topics", [], |r| r.get(0)).unwrap();
        assert_eq!(name, "Mosaic");
        let cursor: i64 = conn.query_row("SELECT pull_cursor FROM device", [], |r| r.get(0)).unwrap();
        assert_eq!(cursor, 7);
    }

    #[test]
    fn a_later_version_replaces_text_and_the_attachment_set() {
        let (_d, conn) = fresh();
        let first = page(serde_json::json!({
            "items": [item("i", "v1", vec![attachment("a0"), attachment("a1")])],
            "topics": [], "tombstones": [], "cursor": 1, "has_more": false,
        }));
        apply_pull(&conn, &first).unwrap();
        let second = page(serde_json::json!({
            "items": [item("i", "v2", vec![attachment("a1"), attachment("a2")])],
            "topics": [], "tombstones": [], "cursor": 2, "has_more": false,
        }));
        apply_pull(&conn, &second).unwrap();
        apply_pull(&conn, &second).unwrap(); // a retried page changes nothing

        let text: String = conn.query_row("SELECT text FROM items", [], |r| r.get(0)).unwrap();
        assert_eq!(text, "v2");
        assert_eq!(attachment_ids(&conn), ["a1", "a2"]);
    }

    #[test]
    fn a_tombstone_deletes_the_item_and_its_attachments() {
        let (_d, conn) = fresh();
        apply_pull(&conn, &page(serde_json::json!({
            "items": [item("i", "x", vec![attachment("a")])],
            "topics": [], "tombstones": [], "cursor": 1, "has_more": false,
        }))).unwrap();
        apply_pull(&conn, &page(serde_json::json!({
            "items": [], "topics": [], "tombstones": ["i"], "cursor": 2, "has_more": false,
        }))).unwrap();
        let items: i64 = conn.query_row("SELECT count(*) FROM items", [], |r| r.get(0)).unwrap();
        assert_eq!(items, 0);
        assert!(attachment_ids(&conn).is_empty());
    }

    #[test]
    fn an_empty_page_changes_nothing_but_the_cursor() {
        let (_d, conn) = fresh();
        let empty = page(serde_json::json!({"items": [], "topics": [], "tombstones": [], "cursor": 3, "has_more": false}));
        assert!(!apply_pull(&conn, &empty).unwrap());
        let cursor: i64 = conn.query_row("SELECT pull_cursor FROM device", [], |r| r.get(0)).unwrap();
        assert_eq!(cursor, 3);
    }

    #[test]
    fn after_a_cycle() {
        assert_eq!(outcome(&Ok(true), 0), ("synced", Some(POLL_INTERVAL)));
        let failed = Err(SyncError::Failed("down".into()));
        let waits: Vec<u64> = [1, 2, 3, 8, 9, 40]
            .map(|n| outcome(&failed, n).1.unwrap().as_secs())
            .to_vec();
        assert_eq!(waits, [2, 4, 8, 256, 300, 300]);
        assert_eq!(outcome(&failed, 1).0, "offline");
        // A rejected secret waits for Settings: retrying would trip the Server's rate limit.
        assert_eq!(outcome(&Err(SyncError::Unauthorized), 0), ("unauthorized", None));
        assert_eq!(outcome(&Err(SyncError::NotConfigured), 0), ("not_configured", None));
    }
}

#[cfg(test)]
mod server_tests {
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::sync::{Mutex, OnceLock};

    use keyring_core::api::CredentialStoreApi;
    use rusqlite::Connection;

    use super::*;
    use crate::feed::{self, View};

    // In the past, so the Server's cap on future timestamps never applies.
    const T0: i64 = 1_760_000_000_000_000;

    fn server_binary() -> &'static Path {
        static BIN: OnceLock<PathBuf> = OnceLock::new();
        BIN.get_or_init(|| {
            let manifest = Path::new(env!("CARGO_MANIFEST_DIR"));
            let bin = manifest.join("target/test-server/notebank-server");
            let ok = Command::new("go")
                .args(["build", "-o"])
                .arg(&bin)
                .arg("./cmd/notebank-server")
                .current_dir(manifest.join("../../server"))
                .status()
                .expect("run go build (is Go installed?)")
                .success();
            assert!(ok, "go build of the Server failed");
            bin
        })
    }

    fn admin_url() -> String {
        std::env::var("NOTEBANK_TEST_ADMIN_URL").unwrap_or_else(|_| "postgres:///postgres".into())
    }

    fn psql(sql: &str) -> bool {
        Command::new("psql")
            .arg(admin_url())
            .args(["-v", "ON_ERROR_STOP=1", "-qc", sql])
            .stdout(Stdio::null())
            .status()
            .expect("run psql (is Postgres installed?)")
            .success()
    }

    /// A real Server on its own database and port. It isn't running until `start`.
    struct TestServer {
        db_name: String,
        port: u16,
        url: String,
        secret: String,
        attachments: tempfile::TempDir,
        child: Option<Child>,
    }

    impl TestServer {
        fn new() -> Self {
            let db_name = format!("notebank_desktop_test_{}", uuid::Uuid::new_v4().simple());
            assert!(psql(&format!("CREATE DATABASE {db_name}")), "create test database (is Postgres running?)");
            let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
            TestServer {
                db_name,
                port,
                url: format!("http://127.0.0.1:{port}"),
                secret: "test-secret-that-is-at-least-32-characters".into(),
                attachments: tempfile::tempdir().unwrap(),
                child: None,
            }
        }

        fn start(&mut self) {
            let mut db_url = url::Url::parse(&admin_url()).unwrap();
            db_url.set_path(&format!("/{}", self.db_name));
            let child = Command::new(server_binary())
                .env("NOTEBANK_DATABASE_URL", db_url.as_str())
                .env("NOTEBANK_SECRET", &self.secret)
                .env("NOTEBANK_LISTEN_ADDR", format!("127.0.0.1:{}", self.port))
                .env("NOTEBANK_ATTACHMENT_DIR", self.attachments.path())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            self.child = Some(child);
            // The Server migrates before it listens, so an open port means it's ready.
            for _ in 0..100 {
                if std::net::TcpStream::connect(("127.0.0.1", self.port)).is_ok() {
                    return;
                }
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
            panic!("the Server didn't start listening on port {}", self.port);
        }
    }

    impl Drop for TestServer {
        fn drop(&mut self) {
            if let Some(child) = &mut self.child {
                let _ = child.kill();
                let _ = child.wait();
            }
            psql(&format!("DROP DATABASE IF EXISTS {} WITH (FORCE)", self.db_name));
        }
    }

    struct Device {
        _dir: tempfile::TempDir,
        db: Mutex<Connection>,
        secret: keyring_core::Entry,
    }

    fn device(server: &TestServer, secret: &str) -> Device {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        conn.execute("UPDATE device SET server_url = ?1", [&server.url]).unwrap();
        let entry = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        entry.set_password(secret).unwrap();
        Device { _dir: dir, db: Mutex::new(conn), secret: entry }
    }

    async fn sync(d: &Device) -> Result<bool, SyncError> {
        cycle(&d.db, &d.secret, &client()).await
    }

    fn texts(d: &Device) -> Vec<String> {
        let items = feed::list_items(&d.db.lock().unwrap(), &View::All, None).unwrap();
        items.into_iter().map(|i| i.text.unwrap()).collect()
    }

    fn count(d: &Device, table: &str) -> i64 {
        d.db.lock().unwrap().query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0)).unwrap()
    }

    #[tokio::test]
    async fn an_offline_capture_reaches_another_device_in_capture_time_order() {
        let mut server = TestServer::new();
        let a = device(&server, &server.secret);
        let b = device(&server, &server.secret);

        feed::capture(&a.db.lock().unwrap(), "captured offline", T0).unwrap();
        assert!(matches!(sync(&a).await, Err(SyncError::Failed(_))));
        assert_eq!(count(&a, "outbox"), 1, "a failed push lost the op");

        server.start();
        feed::capture(&b.db.lock().unwrap(), "captured later", T0 + 1_000_000).unwrap();
        assert_eq!(sync(&b).await, Ok(true));
        assert_eq!(sync(&a).await, Ok(true));
        assert_eq!(count(&a, "outbox"), 0);
        assert!(feed::list_items(&a.db.lock().unwrap(), &View::All, None).unwrap().iter().all(|i| !i.pending));

        sync(&b).await.unwrap();
        assert_eq!(texts(&b), ["captured later", "captured offline"]);
    }

    #[tokio::test]
    async fn a_repeated_push_changes_nothing() {
        let mut server = TestServer::new();
        server.start();
        let a = device(&server, &server.secret);
        feed::capture(&a.db.lock().unwrap(), "once", T0).unwrap();
        let op: String = a.db.lock().unwrap().query_row("SELECT op FROM outbox", [], |r| r.get(0)).unwrap();
        sync(&a).await.unwrap();
        a.db.lock().unwrap().execute("INSERT INTO outbox (op) VALUES (?1)", [&op]).unwrap();
        sync(&a).await.unwrap();

        let b = device(&server, &server.secret);
        sync(&b).await.unwrap();
        assert_eq!(texts(&b), ["once"]);
    }

    #[tokio::test]
    async fn a_wrong_secret_is_unauthorized() {
        let mut server = TestServer::new();
        server.start();
        let a = device(&server, "not-the-secret");
        feed::capture(&a.db.lock().unwrap(), "kept", T0).unwrap();
        assert_eq!(sync(&a).await, Err(SyncError::Unauthorized));
        assert_eq!(count(&a, "outbox"), 1);
    }

    #[tokio::test]
    async fn more_than_a_page_pushes_and_pulls_in_batches() {
        let mut server = TestServer::new();
        server.start();
        let a = device(&server, &server.secret);
        for i in 0..501 {
            feed::capture(&a.db.lock().unwrap(), &format!("item {i}"), T0 + i).unwrap();
        }
        sync(&a).await.unwrap();
        assert_eq!(count(&a, "outbox"), 0);

        let b = device(&server, &server.secret);
        sync(&b).await.unwrap();
        assert_eq!(count(&b, "items"), 501);
    }
}
