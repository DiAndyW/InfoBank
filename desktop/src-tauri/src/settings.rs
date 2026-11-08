use keyring_core::Entry;
use rusqlite::Connection;

#[derive(serde::Serialize)]
pub struct Settings {
    pub server_url: Option<String>,
    pub has_secret: bool,
    pub quick_capture: crate::shortcut::Hotkey,
}

pub fn get(conn: &Connection, secret: &Entry) -> Result<Settings, String> {
    let server_url = conn
        .query_row("SELECT server_url FROM device", [], |r| r.get(0))
        .map_err(|e| e.to_string())?;
    let has_secret = match secret.get_password() {
        Ok(_) => true,
        Err(keyring_core::Error::NoEntry) => false,
        Err(e) => return Err(format!("Couldn't read the keychain: {e}")),
    };
    Ok(Settings { server_url, has_secret, quick_capture: crate::shortcut::get(conn)? })
}

pub fn normalize_url(input: &str) -> Result<String, String> {
    let url = url::Url::parse(input.trim())
        .map_err(|_| "Enter the Server URL, starting with https://".to_string())?;
    let local = matches!(url.host_str(), Some("localhost" | "127.0.0.1"));
    if !(url.scheme() == "https" || (url.scheme() == "http" && local)) || url.host_str().is_none() {
        return Err("The Server URL must start with https://".into());
    }
    Ok(url.as_str().trim_end_matches('/').to_string())
}

pub async fn check_server(http: &reqwest::Client, url: &str, secret: &str) -> Result<(), String> {
    let res = http
        .get(format!("{url}/auth/check"))
        .bearer_auth(secret)
        .timeout(crate::sync::HTTP_TIMEOUT)
        .send()
        .await
        .map_err(|_| "Couldn't reach the Server.")?;
    let status = res.status();
    if status.is_success() {
        return Ok(());
    }
    Err(match status.as_u16() {
        401 => "The Server rejected this secret.".to_string(),
        429 => match res.headers().get("retry-after").and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok()) {
            Some(seconds) => {
                let minutes = seconds.div_ceil(60);
                format!("Too many failed attempts. Try again in {minutes} minute{}.", if minutes == 1 { "" } else { "s" })
            }
            None => "Too many failed attempts. Try again later.".to_string(),
        },
        code => format!("Couldn't check the Server: it answered {code}."),
    })
}

#[derive(serde::Serialize, serde::Deserialize, Clone, Copy, Default, Debug, PartialEq)]
pub struct Stranded {
    pub changes: i64,
    pub files: i64,
}

#[derive(serde::Serialize, Debug, PartialEq)]
#[serde(untagged)]
pub enum SaveError {
    Message(String),
    Stranded { changes: i64, files: i64, message: String },
}

impl From<String> for SaveError {
    fn from(message: String) -> Self {
        SaveError::Message(message)
    }
}

// Ops naming rows the old Server sent us; the new Server has no such rows to apply them to.
const DOOMED_WORK: &str = "(json_extract(op, '$.item_id') IN
        (SELECT id FROM items WHERE id NOT IN
            (SELECT json_extract(op, '$.item_id') FROM outbox WHERE json_extract(op, '$.type') = 'CaptureItem'))
     OR json_extract(op, '$.topic_id') IN
        (SELECT id FROM topics WHERE id NOT IN
            (SELECT json_extract(op, '$.topic_id') FROM outbox WHERE json_extract(op, '$.type') = 'CreateTopic')))";

fn stranded(conn: &Connection) -> rusqlite::Result<Stranded> {
    let changes = conn.query_row(
        &format!(
            "SELECT count(*) FROM outbox
             WHERE json_extract(op, '$.type') NOT IN ('CaptureItem', 'CreateTopic', 'AddAttachment') AND {DOOMED_WORK}"
        ),
        [],
        |r| r.get(0),
    )?;
    let files = conn.query_row(
        "SELECT count(*) FROM attachments WHERE uploaded = 0 AND item_id NOT IN
             (SELECT json_extract(op, '$.item_id') FROM outbox WHERE json_extract(op, '$.type') = 'CaptureItem')",
        [],
        |r| r.get(0),
    )?;
    Ok(Stranded { changes, files })
}

fn stranded_message(s: Stranded) -> String {
    let plural = |n: i64, noun: &str| format!("{n} {noun}{}", if n == 1 { "" } else { "s" });
    let mut parts = Vec::new();
    if s.changes > 0 {
        parts.push(plural(s.changes, "change"));
    }
    if s.files > 0 {
        parts.push(plural(s.files, "file"));
    }
    let verb = if s.changes + s.files == 1 { "hasn't" } else { "haven't" };
    format!("{} {verb} reached the current Server yet. Switching discards this work for good.", parts.join(" and "))
}

/// `server_url` must already be normalised.
pub fn save(conn: &Connection, secret: &Entry, server_url: &str, new_secret: Option<&str>, confirmed: Stranded) -> Result<(), SaveError> {
    let db = |e: rusqlite::Error| e.to_string();
    let new_secret = match new_secret.map(str::trim) {
        Some("") => return Err("The secret can't be blank".to_string().into()),
        Some(s) => Some(s),
        None => {
            let current = get(conn, secret)?;
            if !current.has_secret {
                return Err("Enter the shared secret".to_string().into());
            }
            // A mistyped URL must not receive the secret.
            if current.server_url.as_deref() != Some(server_url) {
                return Err("Enter the secret again for a new Server".to_string().into());
            }
            None
        }
    };

    let tx = conn.unchecked_transaction().map_err(db)?;
    let new_server: bool =
        tx.query_row("SELECT server_url IS NOT ?1 FROM device", [server_url], |r| r.get(0)).map_err(db)?;
    if new_server {
        let found = stranded(&tx).map_err(db)?;
        if found.changes > confirmed.changes || found.files > confirmed.files {
            return Err(SaveError::Stranded { changes: found.changes, files: found.files, message: stranded_message(found) });
        }
        // A cursor and mirror only mean something to the Server they came from; unsynced Captures and Topics go to the new one.
        tx.execute_batch(&format!(
            "DELETE FROM outbox WHERE json_extract(op, '$.type') NOT IN ('CaptureItem', 'CreateTopic') AND {DOOMED_WORK};
             DELETE FROM items WHERE id NOT IN
                 (SELECT json_extract(op, '$.item_id') FROM outbox WHERE json_extract(op, '$.type') = 'CaptureItem');
             DELETE FROM topics WHERE id NOT IN
                 (SELECT json_extract(op, '$.topic_id') FROM outbox WHERE json_extract(op, '$.type') = 'CreateTopic');
             UPDATE device SET pull_cursor = 0;"
        ))
        .map_err(db)?;
    }
    tx.execute("UPDATE device SET server_url = ?1", [server_url]).map_err(db)?;

    // The keychain goes last so only a failed commit needs undoing.
    let mut replaced_secret = None;
    if let Some(s) = new_secret {
        let keychain = |e: keyring_core::Error| format!("Couldn't save to the keychain: {e}");
        replaced_secret = match secret.get_password() {
            Ok(previous) => Some(Some(previous)),
            Err(keyring_core::Error::NoEntry) => Some(None),
            Err(e) => return Err(keychain(e).into()),
        };
        secret.set_password(s).map_err(keychain)?;
    }
    if let Err(e) = tx.commit() {
        if let Some(previous) = replaced_secret {
            let _ = match previous {
                Some(p) => secret.set_password(&p),
                None => secret.delete_credential(),
            };
        }
        return Err(e.to_string().into());
    }
    Ok(())
}

pub async fn save_checked(
    db: &std::sync::Mutex<Connection>,
    secret: &Entry,
    http: &reqwest::Client,
    server_url: &str,
    new_secret: Option<&str>,
    confirmed: Stranded,
) -> Result<(), SaveError> {
    let url = normalize_url(server_url)?;
    if let Some(typed) = new_secret.map(str::trim).filter(|s| !s.is_empty()) {
        check_server(http, &url, typed).await?;
    }
    save(&db.lock().unwrap(), secret, &url, new_secret, confirmed)
}

pub fn trash_after_copy(conn: &Connection) -> Result<Option<bool>, String> {
    conn.query_row("SELECT trash_after_copy FROM settings WHERE id = 1", [], |r| r.get(0)).map_err(|e| e.to_string())
}

pub fn set_trash_after_copy(conn: &Connection, on: bool, now_us: i64) -> Result<(), String> {
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    crate::ops::queue(&tx, crate::ops::Op::SetTrashAfterCopy { value: on }, now_us)?;
    tx.commit().map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use keyring_core::api::CredentialStoreApi;

    fn env() -> (tempfile::TempDir, Connection, Entry) {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        // A fresh in-memory keychain per test; nothing touches the real Keychain.
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        (dir, conn, secret)
    }

    fn cursor(conn: &Connection) -> i64 {
        conn.query_row("SELECT pull_cursor FROM device", [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn first_launch_has_nothing_set() {
        let (_d, conn, secret) = env();
        let s = get(&conn, &secret).unwrap();
        assert_eq!(s.server_url, None);
        assert!(!s.has_secret);
        assert!(s.quick_capture.on);
    }

    #[test]
    fn url_validation() {
        let ok = [
            ("https://notes.example.com", "https://notes.example.com"),
            ("  https://notes.example.com/  ", "https://notes.example.com"),
            ("HTTPS://Notes.Example.com", "https://notes.example.com"),
            ("http://localhost:8080", "http://localhost:8080"),
            ("http://127.0.0.1:8080/", "http://127.0.0.1:8080"),
        ];
        for (input, stored) in ok {
            let (_d, conn, secret) = env();
            let url = normalize_url(input).unwrap_or_else(|e| panic!("{input:?} rejected: {e}"));
            save(&conn, &secret, &url, Some("s3cret"), Stranded::default()).unwrap();
            assert_eq!(get(&conn, &secret).unwrap().server_url.as_deref(), Some(stored), "input {input:?}");
        }
        for input in ["http://notes.example.com", "notes.example.com", "", "ftp://localhost", "https://"] {
            assert!(normalize_url(input).is_err(), "{input:?} accepted");
        }
    }

    #[test]
    fn secret_round_trips_trimmed_and_is_never_returned() {
        let (_d, conn, secret) = env();
        save(&conn, &secret, "https://notes.example.com", Some("  s3cret\n"), Stranded::default()).unwrap();
        assert_eq!(secret.get_password().unwrap(), "s3cret");
        let json = serde_json::to_string(&get(&conn, &secret).unwrap()).unwrap();
        assert!(json.contains("\"has_secret\":true"), "{json}");
        assert!(!json.contains("s3cret"), "settings leaked the secret: {json}");
    }

    #[test]
    fn saving_without_a_secret_keeps_the_stored_one() {
        let (_d, conn, secret) = env();
        save(&conn, &secret, "https://a.example.com", Some("s3cret"), Stranded::default()).unwrap();
        save(&conn, &secret, "https://a.example.com", None, Stranded::default()).unwrap();
        assert_eq!(secret.get_password().unwrap(), "s3cret");
    }

    #[test]
    fn a_new_server_needs_the_secret_again() {
        let (_d, conn, secret) = env();
        save(&conn, &secret, "https://a.example.com", Some("s3cret"), Stranded::default()).unwrap();
        let err = save(&conn, &secret, "https://b.example.com", None, Stranded::default()).unwrap_err();
        assert_eq!(err, SaveError::Message("Enter the secret again for a new Server".into()));
        assert_eq!(get(&conn, &secret).unwrap().server_url.as_deref(), Some("https://a.example.com"));
    }

    #[test]
    fn a_secret_is_required_the_first_time() {
        let (_d, conn, secret) = env();
        assert!(save(&conn, &secret, "https://notes.example.com", None, Stranded::default()).is_err());
        assert!(save(&conn, &secret, "https://notes.example.com", Some("   "), Stranded::default()).is_err());
        assert_eq!(get(&conn, &secret).unwrap().server_url, None);
    }

    #[test]
    fn keychain_failure_saves_nothing() {
        struct DenyWrites;
        impl keyring_core::api::CredentialApi for DenyWrites {
            fn set_secret(&self, _: &[u8]) -> keyring_core::Result<()> {
                Err(keyring_core::Error::Invalid("keychain".into(), "denied".into()))
            }
            fn get_secret(&self) -> keyring_core::Result<Vec<u8>> {
                Err(keyring_core::Error::NoEntry)
            }
            fn delete_credential(&self) -> keyring_core::Result<()> {
                Err(keyring_core::Error::NoEntry)
            }
            fn get_credential(&self) -> keyring_core::Result<Option<std::sync::Arc<keyring_core::Credential>>> {
                Ok(None)
            }
            fn get_specifiers(&self) -> Option<(String, String)> {
                None
            }
            fn as_any(&self) -> &dyn std::any::Any {
                self
            }
        }
        let (_d, conn, secret) = connected_to_a();
        conn.execute("UPDATE device SET pull_cursor = 7", []).unwrap();
        let denied = Entry::new_with_credential(std::sync::Arc::new(DenyWrites));
        let r = save(&conn, &denied, "https://b.example.com", Some("new"), Stranded { changes: 0, files: 1 });
        match r {
            Err(SaveError::Message(m)) => assert!(m.starts_with("Couldn't save to the keychain"), "{m}"),
            other => panic!("{other:?}"),
        }
        assert_eq!(get(&conn, &secret).unwrap().server_url.as_deref(), Some("https://a.example.com"));
        assert_eq!((count(&conn, "items"), cursor(&conn)), (1, 7));
    }

    #[test]
    fn a_new_server_without_a_retyped_secret_is_refused_before_the_discard_dialog() {
        let (_d, conn, secret) = connected_to_a();
        let r = save(&conn, &secret, "https://b.example.com", None, Stranded::default());
        assert_eq!(r, Err(SaveError::Message("Enter the secret again for a new Server".into())));
    }

    #[test]
    fn changing_the_url_resets_the_pull_cursor() {
        let (_d, conn, secret) = env();
        save(&conn, &secret, "https://a.example.com", Some("s3cret"), Stranded::default()).unwrap();
        conn.execute("UPDATE device SET pull_cursor = 42", []).unwrap();

        save(&conn, &secret, "https://a.example.com", None, Stranded::default()).unwrap();
        assert_eq!(cursor(&conn), 42, "the same Server reset the cursor");

        save(&conn, &secret, "https://b.example.com", Some("s3cret"), Stranded::default()).unwrap();
        assert_eq!(cursor(&conn), 0, "a new Server kept the old cursor");
    }

    #[test]
    fn a_new_server_clears_the_old_ones_items_but_keeps_unsynced_captures_and_topics() {
        let (d, conn, secret) = env();
        save(&conn, &secret, "https://a.example.com", Some("s3cret"), Stranded::default()).unwrap();
        conn.execute_batch(
            "INSERT INTO items (id, text, capture_time) VALUES ('pulled', 'x', 1);
             INSERT INTO topics (id, name) VALUES ('old', 'Old');",
        )
        .unwrap();
        crate::feed::capture(&conn, d.path(), "unsynced", &[], &crate::feed::Target::Inbox, None, 2).unwrap();
        crate::topics::create(&conn, "Mine", 3).unwrap();
        let count = |table: &str| -> i64 { conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0)).unwrap() };

        save(&conn, &secret, "https://a.example.com", None, Stranded::default()).unwrap();
        assert_eq!(count("items"), 2, "the same Server lost Items");

        save(&conn, &secret, "https://b.example.com", Some("s3cret"), Stranded::default()).unwrap();
        let text: String = conn.query_row("SELECT text FROM items", [], |r| r.get(0)).unwrap();
        let name: String = conn.query_row("SELECT name FROM topics", [], |r| r.get(0)).unwrap();
        assert_eq!((count("items"), text.as_str(), count("topics"), name.as_str()), (1, "unsynced", 1, "Mine"));
        assert_eq!(count("outbox"), 2);
    }

    #[test]
    fn trash_after_copy_can_be_answered_and_changed_offline() {
        let (_d, conn, _secret) = env();
        assert_eq!(trash_after_copy(&conn).unwrap(), None);
        for value in [true, false] {
            set_trash_after_copy(&conn, value, 1).unwrap();
            assert_eq!(trash_after_copy(&conn).unwrap(), Some(value));
        }
        let mut stmt = conn.prepare("SELECT op FROM outbox ORDER BY seq").unwrap();
        let ops: Vec<serde_json::Value> = stmt.query_map([], |r| r.get::<_, String>(0)).unwrap()
            .map(|s| serde_json::from_str(&s.unwrap()).unwrap()).collect();
        assert_eq!(ops.len(), 2);
        assert_eq!(ops[0]["type"], "SetTrashAfterCopy");
        assert_eq!(ops[0]["value"], true);
        assert_eq!(ops[1]["value"], false);
    }

    use crate::sync::server_tests::TestServer;

    fn count(conn: &Connection, table: &str) -> i64 {
        conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0)).unwrap()
    }

    fn outbox_types(conn: &Connection) -> Vec<String> {
        let mut stmt = conn.prepare("SELECT json_extract(op, '$.type') FROM outbox ORDER BY seq").unwrap();
        stmt.query_map([], |r| r.get(0)).unwrap().map(Result::unwrap).collect()
    }

    // Connected to A, with a pulled Item "pulled" that has one unuploaded file and a pulled Topic "old".
    fn connected_to_a() -> (tempfile::TempDir, Connection, Entry) {
        let (d, conn, secret) = env();
        save(&conn, &secret, "https://a.example.com", Some("s3cret"), Stranded::default()).unwrap();
        conn.execute_batch(
            "INSERT INTO items (id, text, capture_time) VALUES ('pulled', 'x', 1);
             INSERT INTO topics (id, name) VALUES ('old', 'Old');
             INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES ('f1', 'pulled', 'f.png', 'image/png', 1, 0, 0);",
        )
        .unwrap();
        (d, conn, secret)
    }

    fn stranded_error(r: Result<(), SaveError>) -> (i64, i64, String) {
        match r {
            Err(SaveError::Stranded { changes, files, message }) => (changes, files, message),
            other => panic!("expected a Stranded refusal, got {other:?}"),
        }
    }

    async fn check(url: &str, secret: &str) -> Result<(), String> {
        check_server(&crate::sync::client(), url, secret).await
    }

    fn answer_once(response: &'static str) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            let (mut stream, _) = listener.accept().unwrap();
            let mut buf = [0u8; 1024];
            let _ = stream.read(&mut buf);
            stream.write_all(response.as_bytes()).unwrap();
        });
        url
    }

    #[tokio::test]
    async fn check_server_accepts_the_right_secret() {
        let mut server = TestServer::new();
        server.start();
        assert_eq!(check(&server.url, &server.secret).await, Ok(()));
    }

    #[tokio::test]
    async fn check_server_rejects_a_wrong_secret() {
        let mut server = TestServer::new();
        server.start();
        assert_eq!(check(&server.url, "wrong").await, Err("The Server rejected this secret.".into()));
    }

    #[tokio::test]
    async fn check_server_after_ten_failures_says_when_to_retry() {
        let mut server = TestServer::new();
        server.start();
        for _ in 0..10 {
            let _ = check(&server.url, "wrong").await;
        }
        assert_eq!(
            check(&server.url, &server.secret).await,
            Err("Too many failed attempts. Try again in 15 minutes.".into())
        );
    }

    #[tokio::test]
    async fn check_server_unreachable() {
        let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        assert_eq!(check(&format!("http://127.0.0.1:{port}"), "s").await, Err("Couldn't reach the Server.".into()));
    }

    #[tokio::test]
    async fn check_server_other_status() {
        let url = answer_once("HTTP/1.1 502 Bad Gateway\r\ncontent-length: 0\r\n\r\n");
        assert_eq!(check(&url, "s").await, Err("Couldn't check the Server: it answered 502.".into()));
        let url = answer_once("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:1/\r\ncontent-length: 0\r\n\r\n");
        assert_eq!(check(&url, "s").await, Err("Couldn't check the Server: it answered 302.".into()));
    }

    #[tokio::test]
    async fn a_server_that_fails_the_check_leaves_the_device_untouched() {
        let mut server = TestServer::new();
        server.start();
        let dead_port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
        let http = crate::sync::client();
        for (url, typed, expected) in [
            (server.url.clone(), "wrong".to_string(), "The Server rejected this secret."),
            (format!("http://127.0.0.1:{dead_port}"), "any".to_string(), "Couldn't reach the Server."),
        ] {
            let (_d, conn, secret) = connected_to_a();
            conn.execute("UPDATE device SET pull_cursor = 7", []).unwrap();
            let db = std::sync::Mutex::new(conn);
            let r = save_checked(&db, &secret, &http, &url, Some(&typed), Stranded { changes: 0, files: 1 }).await;
            assert_eq!(r, Err(SaveError::Message(expected.into())));
            let conn = db.lock().unwrap();
            assert_eq!((count(&conn, "items"), count(&conn, "topics"), count(&conn, "attachments"), cursor(&conn)), (1, 1, 1, 7));
            assert_eq!(get(&conn, &secret).unwrap().server_url.as_deref(), Some("https://a.example.com"));
            assert_eq!(secret.get_password().unwrap(), "s3cret");
        }
    }

    #[tokio::test]
    async fn a_server_that_passes_the_check_is_switched_to() {
        let mut server = TestServer::new();
        server.start();
        let (_d, conn, secret) = connected_to_a();
        let db = std::sync::Mutex::new(conn);
        save_checked(&db, &secret, &crate::sync::client(), &server.url, Some(&server.secret), Stranded { changes: 0, files: 1 })
            .await
            .unwrap();
        let conn = db.lock().unwrap();
        assert_eq!((count(&conn, "items"), cursor(&conn)), (0, 0));
        assert_eq!(get(&conn, &secret).unwrap().server_url.as_deref(), Some(server.url.as_str()));
        assert_eq!(secret.get_password().unwrap(), server.secret);
    }

    #[test]
    fn a_synced_item_with_an_unuploaded_file_blocks_the_switch() {
        let (_d, conn, secret) = connected_to_a();
        conn.execute("UPDATE device SET pull_cursor = 7", []).unwrap();
        let r = save(&conn, &secret, "https://b.example.com", Some("new"), Stranded::default());
        assert_eq!(
            r,
            Err(SaveError::Stranded {
                changes: 0,
                files: 1,
                message: "1 file hasn't reached the current Server yet. Switching discards this work for good.".into()
            })
        );
        assert_eq!(count(&conn, "items"), 1);
        assert_eq!(cursor(&conn), 7);
        assert_eq!(get(&conn, &secret).unwrap().server_url.as_deref(), Some("https://a.example.com"));
        assert_eq!(secret.get_password().unwrap(), "s3cret");
    }

    #[test]
    fn pending_changes_on_synced_rows_block_the_switch() {
        let (_d, conn, secret) = connected_to_a();
        conn.execute("UPDATE attachments SET uploaded = 1", []).unwrap();
        crate::ops::queue(&conn, crate::ops::Op::SetText { item_id: "pulled".into(), text: Some("y".into()), base_rev: 0 }, 2).unwrap();
        crate::ops::queue(&conn, crate::ops::Op::TrashItem { item_id: "pulled".into() }, 3).unwrap();
        crate::ops::queue(&conn, crate::ops::Op::RenameTopic { topic_id: "old".into(), name: "New".into() }, 4).unwrap();
        let (changes, files, message) = stranded_error(save(&conn, &secret, "https://b.example.com", Some("new"), Stranded::default()));
        assert_eq!((changes, files), (3, 0));
        assert!(message.starts_with("3 changes haven't"), "{message}");
        assert_eq!(count(&conn, "outbox"), 3);
    }

    #[test]
    fn a_kept_capture_with_an_unuploaded_file_does_not_block() {
        let (d, conn, secret) = connected_to_a();
        conn.execute("DELETE FROM attachments", []).unwrap();
        let staged = crate::files::stage_bytes(d.path(), "k.txt", b"hello").unwrap();
        crate::feed::capture(&conn, d.path(), "kept", std::slice::from_ref(&staged.id), &crate::feed::Target::Inbox, None, 2).unwrap();

        save(&conn, &secret, "https://b.example.com", Some("new"), Stranded::default()).unwrap();
        crate::files::sweep_staged(&conn, d.path()).unwrap();
        assert_eq!(count(&conn, "items"), 1);
        assert_eq!(count(&conn, "attachments"), 1);
        assert!(d.path().join("files").join(&staged.id).is_dir());
    }

    #[test]
    fn switching_with_confirmed_counts_discards_the_stranded_work() {
        let (d, conn, secret) = connected_to_a();
        crate::ops::queue(&conn, crate::ops::Op::SetText { item_id: "pulled".into(), text: Some("y".into()), base_rev: 0 }, 2).unwrap();
        crate::ops::queue(&conn, crate::ops::Op::TrashItem { item_id: "pulled".into() }, 3).unwrap();
        crate::ops::queue(&conn, crate::ops::Op::RenameTopic { topic_id: "old".into(), name: "New".into() }, 4).unwrap();
        crate::ops::queue(
            &conn,
            crate::ops::Op::AddAttachment {
                item_id: "pulled".into(),
                attachment: crate::ops::NewAttachment { id: "f2".into(), filename: "g.png".into(), mime_type: "image/png".into(), size_bytes: 1 },
            },
            5,
        )
        .unwrap();
        let staged = crate::files::stage_bytes(d.path(), "k.txt", b"hello").unwrap();
        crate::feed::capture(&conn, d.path(), "kept", &[staged.id], &crate::feed::Target::Inbox, None, 6).unwrap();
        let kept: String = conn.query_row("SELECT id FROM items WHERE text = 'kept'", [], |r| r.get(0)).unwrap();
        crate::ops::queue(
            &conn,
            crate::ops::Op::AddAttachment {
                item_id: kept,
                attachment: crate::ops::NewAttachment { id: "f3".into(), filename: "h.png".into(), mime_type: "image/png".into(), size_bytes: 1 },
            },
            6,
        )
        .unwrap();
        set_trash_after_copy(&conn, true, 7).unwrap();
        conn.execute("UPDATE device SET pull_cursor = 9", []).unwrap();

        save(&conn, &secret, "https://b.example.com", Some("new"), Stranded { changes: 3, files: 2 }).unwrap();
        assert_eq!(count(&conn, "attachments"), 2, "the doomed Items' files stayed");
        assert_eq!(outbox_types(&conn), ["CaptureItem", "AddAttachment", "SetTrashAfterCopy"]);
        assert_eq!(count(&conn, "items"), 1);
        assert_eq!(count(&conn, "topics"), 0);
        assert_eq!(cursor(&conn), 0);
        assert_eq!(get(&conn, &secret).unwrap().server_url.as_deref(), Some("https://b.example.com"));
        assert_eq!(secret.get_password().unwrap(), "new");
    }

    #[test]
    fn more_stranded_work_than_confirmed_refuses_again() {
        let (_d, conn, secret) = connected_to_a();
        conn.execute("UPDATE attachments SET uploaded = 1", []).unwrap();
        crate::ops::queue(&conn, crate::ops::Op::SetText { item_id: "pulled".into(), text: Some("y".into()), base_rev: 0 }, 2).unwrap();
        crate::ops::queue(&conn, crate::ops::Op::TrashItem { item_id: "pulled".into() }, 3).unwrap();
        let r = save(&conn, &secret, "https://b.example.com", Some("new"), Stranded { changes: 1, files: 0 });
        assert_eq!(stranded_error(r).0, 2);
        assert_eq!(count(&conn, "outbox"), 2);
        assert_eq!(count(&conn, "items"), 1);
        assert_eq!(secret.get_password().unwrap(), "s3cret");
    }

    #[test]
    fn a_capture_into_an_old_topic_is_kept_but_a_move_into_one_counts() {
        let (d, conn, secret) = connected_to_a();
        conn.execute("DELETE FROM attachments", []).unwrap();
        crate::feed::capture(&conn, d.path(), "kept", &[], &crate::feed::Target::Topic { id: "old".into() }, None, 2).unwrap();
        save(&conn, &secret, "https://b.example.com", Some("new"), Stranded::default()).unwrap();

        let (d, conn, secret) = connected_to_a();
        conn.execute("DELETE FROM attachments", []).unwrap();
        crate::feed::capture(&conn, d.path(), "kept", &[], &crate::feed::Target::Inbox, None, 2).unwrap();
        let kept: String = conn.query_row("SELECT id FROM items WHERE text = 'kept'", [], |r| r.get(0)).unwrap();
        crate::ops::queue(&conn, crate::ops::Op::MoveItem { item_id: kept, topic_id: Some("old".into()), tunnel: false }, 3).unwrap();
        let (changes, files, _) = stranded_error(save(&conn, &secret, "https://b.example.com", Some("new"), Stranded::default()));
        assert_eq!((changes, files), (1, 0));
    }

    #[test]
    fn first_save_counts_nothing_and_keeps_pre_setup_captures() {
        let (d, conn, secret) = env();
        let staged = crate::files::stage_bytes(d.path(), "k.txt", b"hello").unwrap();
        crate::feed::capture(&conn, d.path(), "early", &[staged.id], &crate::feed::Target::Inbox, None, 1).unwrap();
        crate::topics::create(&conn, "Mine", 2).unwrap();
        save(&conn, &secret, "https://a.example.com", Some("s3cret"), Stranded::default()).unwrap();
        assert_eq!((count(&conn, "items"), count(&conn, "topics"), count(&conn, "attachments")), (1, 1, 1));
        assert_eq!(outbox_types(&conn), ["CaptureItem", "CreateTopic"]);
    }

    #[test]
    fn stranded_message_wording() {
        let message = |changes, files| stranded_message(Stranded { changes, files });
        let tail = "reached the current Server yet. Switching discards this work for good.";
        for (changes, files, head) in [
            (2, 1, "2 changes and 1 file haven't"),
            (1, 0, "1 change hasn't"),
            (0, 3, "3 files haven't"),
            (1, 1, "1 change and 1 file haven't"),
            (0, 1, "1 file hasn't"),
            (2, 0, "2 changes haven't"),
        ] {
            assert_eq!(message(changes, files), format!("{head} {tail}"));
        }
    }
}
