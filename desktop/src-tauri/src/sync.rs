use std::sync::{Arc, Mutex};
use std::time::Duration;

use chrono::{DateTime, Utc};
use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, Runtime};
use tokio::io::AsyncReadExt;

use crate::AppState;

pub const POLL_INTERVAL: Duration = Duration::from_secs(10);
const MAX_BACKOFF: Duration = Duration::from_secs(300);

#[derive(Debug, PartialEq)]
pub enum SyncError {
    NotConfigured,
    Unauthorized,
    // Includes the user denying the macOS access prompt.
    Keychain(String),
    Failed(String),
}

#[derive(Debug, PartialEq)]
pub enum Wait {
    For(Duration),
    UntilSettingsSaved,
    // Window focus, a Capture or saved Settings.
    UntilWoken,
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
    text_rev: i64,
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
            "INSERT INTO items (id, topic_id, text, capture_time, deleted_at, purge_at, text_rev)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT (id) DO UPDATE SET
                topic_id = excluded.topic_id, text = excluded.text, capture_time = excluded.capture_time,
                deleted_at = excluded.deleted_at, purge_at = excluded.purge_at,
                text_rev = excluded.text_rev, sync_error = NULL",
            (&it.id, &it.topic_id, &it.text, it.capture_time.timestamp_micros(), micros(it.deleted_at), micros(it.purge_at), it.text_rev),
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
    crate::ops::replay(&tx)?;
    tx.execute("UPDATE device SET pull_cursor = ?1", [page.cursor])?;
    tx.commit()?;
    Ok(!(page.items.is_empty() && page.topics.is_empty() && page.tombstones.is_empty()))
}

/// The status to show after a cycle and what to wait for before the next.
pub fn outcome(result: &Result<bool, SyncError>, failures: u32) -> (&'static str, Wait) {
    match result {
        Ok(_) => ("synced", Wait::For(POLL_INTERVAL)),
        Err(SyncError::Failed(_)) => ("offline", Wait::For(Duration::from_secs(2u64.saturating_pow(failures)).min(MAX_BACKOFF))),
        Err(SyncError::Unauthorized) => ("unauthorized", Wait::UntilSettingsSaved),
        Err(SyncError::NotConfigured) => ("not_configured", Wait::UntilSettingsSaved),
        // Retrying on a timer would show the macOS prompt again and again.
        Err(SyncError::Keychain(_)) => ("keychain", Wait::UntilWoken),
    }
}

const HTTP_TIMEOUT: Duration = Duration::from_secs(30);
// 100 MB transfers get no total limit, only IDLE_TIMEOUT; reqwest's read_timeout would also cap sending an upload's body.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(10);
pub const IDLE_TIMEOUT: Duration = Duration::from_secs(if cfg!(test) { 2 } else { 30 });
// The Server's per-push op limit.
const PUSH_BATCH: i64 = 500;

pub fn client() -> reqwest::Client {
    reqwest::Client::builder()
        .connect_timeout(CONNECT_TIMEOUT)
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
    text: Option<String>,
}

/// A refusal or redirect the user should hear about; `topic_state` and `place` are filled in after the pull.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct SyncNotice {
    pub kind: &'static str,
    pub item_id: String,
    pub label: String,
    pub topic: Option<String>,
    pub topic_state: Option<&'static str>,
    pub place: Option<String>,
    #[serde(skip)]
    topic_id: Option<String>,
}

fn label(conn: &Connection, item_id: &str) -> Option<String> {
    let text: Option<String> =
        conn.query_row("SELECT text FROM items WHERE id = ?1", [item_id], |r| r.get(0)).optional().ok()?.flatten();
    let line = text.map(|t| t.split_whitespace().collect::<Vec<_>>().join(" ")).filter(|t| !t.is_empty());
    match line {
        Some(l) if l.chars().count() > 40 => Some(l.chars().take(40).collect::<String>() + "…"),
        Some(l) => Some(l),
        None => conn
            .query_row("SELECT filename FROM attachments WHERE item_id = ?1 ORDER BY rowid LIMIT 1", [item_id], |r| r.get(0))
            .optional()
            .ok()?,
    }
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

pub fn server_access(state: &AppState) -> Result<(String, String), SyncError> {
    let url: Option<String> =
        state.db.lock().unwrap().query_row("SELECT server_url FROM device", [], |r| r.get(0)).map_err(failed)?;
    let url = url.ok_or(SyncError::NotConfigured)?;
    match state.secret.get_password() {
        Ok(token) => Ok((url, token)),
        Err(keyring_core::Error::NoEntry) => Err(SyncError::NotConfigured),
        Err(e) => Err(SyncError::Keychain(e.to_string())),
    }
}

pub async fn cycle(state: &AppState) -> Result<bool, SyncError> {
    let (url, token) = server_access(state)?;
    let device_id: String =
        state.db.lock().unwrap().query_row("SELECT device_id FROM device", [], |r| r.get(0)).map_err(failed)?;

    let mut changed = false;
    loop {
        let batch: Vec<(i64, String)> = {
            let conn = state.db.lock().unwrap();
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
        let res = send(state.http.post(format!("{url}/sync/push")).timeout(HTTP_TIMEOUT).json(&body), &token).await?;
        let res: PushResponse = res.json().await.map_err(failed)?;
        let mut notices = Vec::new();
        {
            let conn = state.db.lock().unwrap();
            let tx = conn.unchecked_transaction().map_err(failed)?;
            for r in &res.results {
                let Some(op) = ops.iter().find(|o| o["id"] == r.op_id.as_str()) else { continue };
                let (ty, reason) = (op["type"].as_str().unwrap_or_default(), r.reason.as_deref().unwrap_or_default());
                let item_id = op["item_id"].as_str();
                let rejected = r.status == "rejected";
                if rejected && ty == "CaptureItem" {
                    tx.execute("UPDATE items SET sync_error = ?2 WHERE id = ?1", (item_id, reason)).map_err(failed)?;
                    continue;
                }
                let refused_capture = match item_id {
                    Some(id) => tx
                        .query_row("SELECT sync_error IS NOT NULL FROM items WHERE id = ?1", [id], |r| r.get(0))
                        .optional()
                        .map_err(failed)?
                        .unwrap_or(false),
                    None => false,
                };
                if rejected && refused_capture {
                    continue;
                }
                let conflict = match (r.status.as_str(), ty, reason) {
                    ("rejected", "SetText", "superseded") => Some((op["text"].as_str(), 1)),
                    ("changed", "SetText", "overwrote") => Some((r.text.as_deref(), 0)),
                    _ => None,
                };
                if let (Some((text, mine)), Some(id)) = (conflict, item_id) {
                    tx.execute(
                        "INSERT INTO conflicts (item_id, text, mine) SELECT ?1, ?2, ?3 WHERE EXISTS (SELECT 1 FROM items WHERE id = ?1)
                         ON CONFLICT (item_id) DO UPDATE SET text = excluded.text, mine = excluded.mine",
                        (id, text, mine),
                    )
                    .map_err(failed)?;
                    continue;
                }
                let kind = match (r.status.as_str(), ty, reason) {
                    ("rejected", "MoveItem", "topic_unavailable") => "move",
                    ("rejected", "SetText" | "AddAttachment" | "MoveItem" | "TrashItem" | "RestoreItem", "not_found") => "gone",
                    ("rejected", "RestoreItem", "empty") => "empty",
                    ("changed", "CaptureItem", "sent_to_inbox") => "inbox",
                    _ => {
                        if rejected {
                            eprintln!("sync: op {} rejected: {}", r.op_id, r.reason.as_deref().unwrap_or("no reason"));
                        }
                        continue;
                    }
                };
                let Some(item_id) = item_id else { continue };
                let topic_id = op["topic_id"].as_str().filter(|_| matches!(kind, "move" | "inbox")).map(String::from);
                let topic = topic_id.as_deref().and_then(|t| {
                    tx.query_row("SELECT name FROM topics WHERE id = ?1", [t], |r| r.get(0)).optional().ok().flatten()
                });
                notices.push(SyncNotice {
                    kind,
                    item_id: item_id.into(),
                    label: label(&tx, item_id).unwrap_or_default(),
                    topic,
                    topic_state: None,
                    place: tx
                        .query_row("SELECT topic_id FROM items WHERE id = ?1", [item_id], |r| r.get(0))
                        .optional()
                        .map_err(failed)?
                        .flatten(),
                    topic_id,
                });
            }
            // Every op in the batch got an answer, so all of them leave the outbox; pull brings the Server's version.
            tx.execute("DELETE FROM outbox WHERE seq <= ?1", [last_seq]).map_err(failed)?;
            tx.commit().map_err(failed)?;
        }
        state.notices.lock().unwrap().extend(notices);
        changed = true;
    }
    changed |= pull(state, &url, &token).await?;
    {
        let conn = state.db.lock().unwrap();
        for n in state.notices.lock().unwrap().iter_mut() {
            n.place = conn
                .query_row("SELECT topic_id FROM items WHERE id = ?1", [&n.item_id], |r| r.get(0))
                .optional()
                .map_err(failed)?
                .flatten();
            n.topic_state = n.topic_id.as_deref().and_then(|t| {
                let state: Option<String> = conn
                    .query_row(
                        "SELECT CASE WHEN deleted_at IS NOT NULL THEN 'deleted' WHEN archived_at IS NOT NULL THEN 'archived' END
                         FROM topics WHERE id = ?1",
                        [t],
                        |r| r.get(0),
                    )
                    .optional()
                    .ok()
                    .flatten()
                    .flatten();
                state.map(|s| if s == "deleted" { "deleted" } else { "archived" })
            });
        }
    }
    match upload_pending(state, &url, &token).await {
        Ok(false) => {}
        Ok(true) => {
            changed = true;
            let _ = pull(state, &url, &token).await;
        }
        Err(e) if !changed => return Err(e),
        // The Feed must still hear about what was pulled; the next cycle retries and reports the error.
        Err(_) => {}
    }
    Ok(changed)
}

async fn pull(state: &AppState, url: &str, token: &str) -> Result<bool, SyncError> {
    let mut changed = false;
    loop {
        let cursor: i64 =
            state.db.lock().unwrap().query_row("SELECT pull_cursor FROM device", [], |r| r.get(0)).map_err(failed)?;
        let res = send(state.http.get(format!("{url}/sync/pull?cursor={cursor}")).timeout(HTTP_TIMEOUT), token).await?;
        let page: Page = res.json().await.map_err(failed)?;
        changed |= apply_pull(&state.db.lock().unwrap(), &page).map_err(failed)?;
        if !page.has_more {
            return Ok(changed);
        }
    }
}

pub async fn upload_pending(state: &AppState, url: &str, token: &str) -> Result<bool, SyncError> {
    let pending: Vec<(String, String, i64)> = {
        let conn = state.db.lock().unwrap();
        let mut stmt = conn
            .prepare(
                "SELECT a.id, c.path, a.size_bytes FROM attachments a
                 JOIN items i ON i.id = a.item_id
                 JOIN cached_files c ON c.attachment_id = a.id AND c.kind = 'file'
                 WHERE a.uploaded = 0 AND i.sync_error IS NULL ORDER BY a.rowid",
            )
            .map_err(failed)?;
        stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
            .map_err(failed)?
            .collect::<rusqlite::Result<_>>()
            .map_err(failed)?
    };
    let mut finished = false;
    for (id, path, size_bytes) in pending {
        if state.skipped_uploads.lock().unwrap().contains(&id) {
            continue;
        }
        let Ok(file) = tokio::fs::File::open(state.dir.join(&path)).await else {
            eprintln!("sync: attachment {id}: the local file is missing");
            state.skipped_uploads.lock().unwrap().insert(id);
            continue;
        };
        let moved = Arc::new(Mutex::new(tokio::time::Instant::now()));
        let marker = moved.clone();
        let body = futures_util::stream::unfold(file, move |mut file| {
            let marker = marker.clone();
            async move {
                let mut chunk = vec![0; 64 * 1024];
                let read = file.read(&mut chunk).await;
                *marker.lock().unwrap() = tokio::time::Instant::now();
                match read {
                    Ok(0) => None,
                    Ok(n) => {
                        chunk.truncate(n);
                        Some((Ok(chunk), file))
                    }
                    Err(e) => Some((Err(e), file)),
                }
            }
        });
        let send = state
            .http
            .put(format!("{url}/attachments/{id}"))
            .bearer_auth(token)
            .header(reqwest::header::CONTENT_LENGTH, size_bytes)
            .body(reqwest::Body::wrap_stream(body))
            .send();
        tokio::pin!(send);
        let res = loop {
            let idle_until = *moved.lock().unwrap() + IDLE_TIMEOUT;
            match tokio::time::timeout_at(idle_until, &mut send).await {
                Ok(res) => break res.map_err(|e| SyncError::Failed(e.without_url().to_string()))?,
                Err(_) if *moved.lock().unwrap() + IDLE_TIMEOUT <= tokio::time::Instant::now() => {
                    return Err(SyncError::Failed(format!("attachment {id}: the upload stalled")));
                }
                Err(_) => {}
            }
        };
        match res.status() {
            // 410: removed on the Server, so it needs nothing more and the local file can be evicted.
            reqwest::StatusCode::NO_CONTENT | reqwest::StatusCode::GONE => {
                state.db.lock().unwrap().execute("UPDATE attachments SET uploaded = 1 WHERE id = ?1", [&id]).map_err(failed)?;
                finished = true;
            }
            reqwest::StatusCode::NOT_FOUND => {}
            reqwest::StatusCode::BAD_REQUEST => {
                eprintln!("sync: attachment {id}: the Server refused the upload");
                state.skipped_uploads.lock().unwrap().insert(id);
            }
            reqwest::StatusCode::UNAUTHORIZED => return Err(SyncError::Unauthorized),
            s => return Err(SyncError::Failed(format!("the Server answered {s}"))),
        }
    }
    Ok(finished)
}

/// The background loop: one cycle, then wait for a wake-up, the poll interval or the backoff.
pub async fn run<R: Runtime>(app: AppHandle<R>) {
    let state = app.state::<AppState>();
    let mut failures = 0;
    loop {
        // This cycle reads the current Settings, so an earlier save must not wake the wait for the next one.
        std::pin::pin!(state.settings_saved.notified()).enable();
        let pending: bool = state
            .db
            .lock()
            .unwrap()
            .query_row("SELECT EXISTS (SELECT 1 FROM outbox)", [], |r| r.get(0))
            .unwrap_or(false);
        if pending {
            set_status(&app, "syncing");
        }
        let result = cycle(&state).await;
        if let Err(SyncError::Keychain(e)) = &result {
            eprintln!("sync: couldn't read the keychain: {e}");
        }
        failures = if let Err(SyncError::Failed(e)) = &result {
            eprintln!("sync: {e}");
            failures + 1
        } else {
            0
        };
        if result == Ok(true) {
            let _ = app.emit("items-changed", ());
            let now = chrono::Utc::now().timestamp_micros();
            crate::cache::start_prefetch(&app, now);
            if let Err(e) = crate::cache::evict(&state.db.lock().unwrap(), &state.dir, now, crate::cache::FILE_CACHE_BYTES) {
                eprintln!("cache: eviction failed: {e}");
            }
        }
        let notices = std::mem::take(&mut *state.notices.lock().unwrap());
        if !notices.is_empty() {
            let _ = app.emit("sync-notices", notices);
        }
        let (status, wait) = outcome(&result, failures);
        set_status(&app, status);
        match wait {
            Wait::For(d) => {
                let _ = tokio::time::timeout(d, state.wake.notified()).await;
            }
            Wait::UntilSettingsSaved => state.settings_saved.notified().await,
            Wait::UntilWoken => state.wake.notified().await,
        }
    }
}

fn set_status<R: Runtime>(app: &AppHandle<R>, status: &'static str) {
    let state = app.state::<AppState>();
    let mut current = state.status.lock().unwrap();
    if *current != status {
        *current = status;
        let _ = app.emit("sync-status", status);
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
                           "deleted_at": null, "purge_at": null, "text_rev": 0, "attachments": attachments})
    }

    fn attachment_ids(conn: &Connection) -> Vec<String> {
        let mut stmt = conn.prepare("SELECT id FROM attachments ORDER BY id").unwrap();
        stmt.query_map([], |r| r.get(0)).unwrap().collect::<rusqlite::Result<_>>().unwrap()
    }

    #[test]
    fn a_label_is_one_short_line_or_the_first_filename() {
        let (_d, conn) = fresh();
        let long = format!("first   line\n{}\nsecond", "x".repeat(60));
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('t', ?1, 1)", [&long]).unwrap();
        let expected = format!("first line {}…", "x".repeat(29));
        assert_eq!(label(&conn, "t"), Some(expected));

        conn.execute("INSERT INTO items (id, capture_time) VALUES ('f', 1)", []).unwrap();
        conn.execute(
            "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES ('a', 'f', 'scan.png', 'image/png', 1, 1, 0)",
            [],
        )
        .unwrap();
        assert_eq!(label(&conn, "f").as_deref(), Some("scan.png"));
    }

    #[test]
    fn a_pull_that_purges_an_item_with_a_queued_file_still_applies() {
        let (_d, conn) = fresh();
        let pulled = serde_json::json!({"items": [item("i", "x", vec![])], "topics": [], "tombstones": [], "cursor": 1, "has_more": false});
        apply_pull(&conn, &page(pulled)).unwrap();
        let png = crate::ops::NewAttachment { id: "a".into(), filename: "a.png".into(), mime_type: "image/png".into(), size_bytes: 3 };
        crate::ops::queue(&conn, crate::ops::Op::AddAttachment { item_id: "i".into(), attachment: png }, 2).unwrap();
        let purged = serde_json::json!({"items": [], "topics": [], "tombstones": ["i"], "cursor": 2, "has_more": false});
        apply_pull(&conn, &page(purged)).unwrap();
        let cursor: i64 = conn.query_row("SELECT pull_cursor FROM device", [], |r| r.get(0)).unwrap();
        assert_eq!(cursor, 2);
    }

    #[test]
    fn a_pull_stores_the_text_revision_and_clears_a_sync_error() {
        let (_d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time, sync_error) VALUES ('i', 'x', 1, 'exists')", []).unwrap();
        let mut pulled = item("i", "x", vec![]);
        pulled["text_rev"] = 7.into();
        let p = page(serde_json::json!({"items": [pulled], "topics": [], "tombstones": [], "cursor": 1, "has_more": false}));
        apply_pull(&conn, &p).unwrap();
        let (rev, error): (i64, Option<String>) =
            conn.query_row("SELECT text_rev, sync_error FROM items WHERE id = 'i'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!((rev, error), (7, None));
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
    fn a_pull_never_hides_a_change_not_yet_pushed() {
        use crate::ops::{self, Op};
        let (_d, conn) = fresh();
        let rows = |cursor: i64| {
            let mut filed = item("j", "y", vec![]);
            filed["topic_id"] = serde_json::json!("d");
            page(serde_json::json!({
                "items": [item("i", "x", vec![]), filed],
                "topics": [{"id": "t", "name": "Gym", "archived_at": null, "deleted_at": null},
                           {"id": "d", "name": "Old", "archived_at": null, "deleted_at": null}],
                "tombstones": [], "cursor": cursor, "has_more": false,
            }))
        };
        apply_pull(&conn, &rows(1)).unwrap();
        ops::queue(&conn, Op::RenameTopic { topic_id: "t".into(), name: "Lifting".into() }, 5).unwrap();
        ops::queue(&conn, Op::MoveItem { item_id: "i".into(), topic_id: Some("t".into()) }, 5).unwrap();
        ops::queue(&conn, Op::DeleteTopic { topic_id: "d".into(), trash: vec!["j".into()] }, 5).unwrap();

        let state = |conn: &Connection| -> (String, Option<String>, bool, bool) {
            conn.query_row(
                "SELECT (SELECT name FROM topics WHERE id = 't'), (SELECT topic_id FROM items WHERE id = 'i'),
                        (SELECT deleted_at IS NOT NULL FROM topics WHERE id = 'd'),
                        (SELECT deleted_at IS NOT NULL AND topic_id IS NULL FROM items WHERE id = 'j')",
                [],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
            )
            .unwrap()
        };
        // The same rows again, as a pull racing the push would bring them.
        apply_pull(&conn, &rows(2)).unwrap();
        assert_eq!(state(&conn), ("Lifting".into(), Some("t".into()), true, true));

        conn.execute("DELETE FROM outbox", []).unwrap();
        apply_pull(&conn, &rows(3)).unwrap();
        assert_eq!(state(&conn), ("Gym".into(), None, false, false));
    }

    #[test]
    fn after_a_cycle() {
        assert_eq!(outcome(&Ok(true), 0), ("synced", Wait::For(POLL_INTERVAL)));
        let failed = Err(SyncError::Failed("down".into()));
        let waits = [1, 2, 3, 8, 9, 40].map(|n| outcome(&failed, n).1);
        assert_eq!(waits, [2, 4, 8, 256, 300, 300].map(|s| Wait::For(Duration::from_secs(s))));
        assert_eq!(outcome(&failed, 1).0, "offline");
        // A rejected secret waits for Settings: retrying would trip the Server's rate limit.
        assert_eq!(outcome(&Err(SyncError::Unauthorized), 0), ("unauthorized", Wait::UntilSettingsSaved));
        assert_eq!(outcome(&Err(SyncError::NotConfigured), 0), ("not_configured", Wait::UntilSettingsSaved));
        assert_eq!(outcome(&Err(SyncError::Keychain("denied".into())), 0), ("keychain", Wait::UntilWoken));
    }
}

#[cfg(test)]
mod server_tests {
    use std::path::{Path, PathBuf};
    use std::process::{Child, Command, Stdio};
    use std::sync::OnceLock;

    use keyring_core::api::CredentialStoreApi;
    use rusqlite::OptionalExtension;

    use super::*;
    use crate::feed::{self, View};
    use crate::topics::{self, Keep};

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
        state: AppState,
    }

    impl std::ops::Deref for Device {
        type Target = AppState;
        fn deref(&self) -> &AppState {
            &self.state
        }
    }

    fn device(server: &TestServer, secret: &str) -> Device {
        device_at(&server.url, secret)
    }

    fn device_at(url: &str, secret: &str) -> Device {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        conn.execute("UPDATE device SET server_url = ?1", [url]).unwrap();
        let entry = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        entry.set_password(secret).unwrap();
        Device { state: AppState::new(conn, entry, dir.path().to_path_buf()), _dir: dir }
    }

    fn reopen(d: Device) -> Device {
        let Device { _dir, state } = d;
        let AppState { secret, .. } = state;
        let conn = crate::store::open(&_dir.path().join("notebank.db")).unwrap();
        Device { state: AppState::new(conn, secret, _dir.path().to_path_buf()), _dir }
    }

    async fn sync(d: &Device) -> Result<bool, SyncError> {
        cycle(d).await
    }

    fn texts(d: &Device) -> Vec<String> {
        let items = feed::list_items(&d.db.lock().unwrap(), &View::All, None, 0).unwrap();
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

        feed::capture(&a.db.lock().unwrap(), &a.dir, "captured offline", &[], None, T0).unwrap();
        assert!(matches!(sync(&a).await, Err(SyncError::Failed(_))));
        assert_eq!(count(&a, "outbox"), 1, "a failed push lost the op");

        server.start();
        feed::capture(&b.db.lock().unwrap(), &b.dir, "captured later", &[], None, T0 + 1_000_000).unwrap();
        assert_eq!(sync(&b).await, Ok(true));
        assert_eq!(sync(&a).await, Ok(true));
        assert_eq!(count(&a, "outbox"), 0);
        assert!(feed::list_items(&a.db.lock().unwrap(), &View::All, None, 0).unwrap().iter().all(|i| !i.pending));

        sync(&b).await.unwrap();
        assert_eq!(texts(&b), ["captured later", "captured offline"]);
    }

    #[tokio::test]
    async fn a_repeated_push_changes_nothing() {
        let mut server = TestServer::new();
        server.start();
        let a = device(&server, &server.secret);
        feed::capture(&a.db.lock().unwrap(), &a.dir, "once", &[], None, T0).unwrap();
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
        feed::capture(&a.db.lock().unwrap(), &a.dir, "kept", &[], None, T0).unwrap();
        assert_eq!(sync(&a).await, Err(SyncError::Unauthorized));
        assert_eq!(count(&a, "outbox"), 1);
    }

    #[tokio::test]
    async fn more_than_a_page_pushes_and_pulls_in_batches() {
        let mut server = TestServer::new();
        server.start();
        let a = device(&server, &server.secret);
        for i in 0..501 {
            feed::capture(&a.db.lock().unwrap(), &a.dir, &format!("item {i}"), &[], None, T0 + i).unwrap();
        }
        sync(&a).await.unwrap();
        assert_eq!(count(&a, "outbox"), 0);

        let b = device(&server, &server.secret);
        sync(&b).await.unwrap();
        assert_eq!(count(&b, "items"), 501);
    }

    /// A stand-in Server that rejects every request; returns its URL and how many requests it got.
    fn reject_all() -> (String, std::sync::Arc<std::sync::atomic::AtomicUsize>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let requests = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = requests.clone();
        std::thread::spawn(move || {
            for mut stream in listener.incoming().flatten() {
                let _ = std::io::Read::read(&mut stream, &mut [0; 4096]);
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let _ = std::io::Write::write_all(
                    &mut stream,
                    b"HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\nconnection: close\r\n\r\n",
                );
            }
        });
        (url, requests)
    }

    /// The app as the sync loop sees it, set up for `url` with a stored secret.
    fn app_for(url: &str, dir: &tempfile::TempDir) -> tauri::App<tauri::test::MockRuntime> {
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        conn.execute("UPDATE device SET server_url = ?1", [url]).unwrap();
        let secret = keyring_core::mock::Store::new().unwrap().build("svc", "shared-secret", None).unwrap();
        secret.set_password("not-the-secret").unwrap();
        let app = tauri::test::mock_app();
        app.manage(AppState::new(conn, secret, dir.path().to_path_buf()));
        app
    }

    fn seen(requests: &std::sync::atomic::AtomicUsize) -> usize {
        requests.load(std::sync::atomic::Ordering::SeqCst)
    }

    #[tokio::test]
    async fn prefetch_runs_beside_sync_and_one_at_a_time() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let requests = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = requests.clone();
        std::thread::spawn(move || {
            for stream in listener.incoming().flatten() {
                counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                std::thread::spawn(move || {
                    let _held = stream;
                    std::thread::sleep(Duration::from_secs(30));
                });
            }
        });
        let dir = tempfile::tempdir().unwrap();
        let app = app_for(&url, &dir);
        app.state::<AppState>()
            .db
            .lock()
            .unwrap()
            .execute_batch(&format!(
                "INSERT INTO items (id, capture_time) VALUES ('i', {T0});
                 INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
                 VALUES ('{}', 'i', 'p.png', 'image/png', 1, 1, 1);",
                uuid::Uuid::new_v4()
            ))
            .unwrap();

        let started = std::time::Instant::now();
        crate::cache::start_prefetch(app.handle(), T0);
        assert!(started.elapsed() < Duration::from_millis(100), "sync waited for the prefetch");
        for _ in 0..40 {
            if seen(&requests) == 1 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert_eq!(seen(&requests), 1);
        crate::cache::start_prefetch(app.handle(), T0);
        tokio::time::sleep(Duration::from_millis(300)).await;
        assert_eq!(seen(&requests), 1, "a second prefetch ran while the first was still going");
    }

    #[tokio::test]
    async fn a_rejected_secret_is_tried_once_per_save() {
        let (url, requests) = reject_all();
        let dir = tempfile::tempdir().unwrap();
        let app = app_for(&url, &dir);
        // Settings were saved while sync was idle, so nothing was waiting for the notification.
        app.state::<AppState>().settings_saved.notify_one();
        tokio::spawn(run(app.handle().clone()));
        tokio::time::sleep(Duration::from_millis(500)).await;

        assert_eq!(seen(&requests), 1, "each failure counts toward the Server's lockout");
        assert_eq!(*app.state::<AppState>().status.lock().unwrap(), "unauthorized");
    }

    #[tokio::test]
    async fn a_keychain_error_waits_for_the_user() {
        let (url, requests) = reject_all();
        let dir = tempfile::tempdir().unwrap();
        let app = app_for(&url, &dir);
        let state = app.state::<AppState>();
        // Fails the next read only, as when the user denies the macOS prompt once.
        let mock: &keyring_core::mock::Cred = state.secret.as_any().downcast_ref().unwrap();
        mock.set_error(keyring_core::Error::PlatformFailure("User canceled the operation.".into()));
        tokio::spawn(run(app.handle().clone()));

        // Longer than the first backoff, so a retry on a timer would have reached the Server.
        tokio::time::sleep(Duration::from_millis(2500)).await;
        assert_eq!(seen(&requests), 0, "retried without the user asking");
        assert_eq!(*state.status.lock().unwrap(), "keychain");

        state.wake.notify_one(); // window focus
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert_eq!(seen(&requests), 1);
    }

    const PIXEL_PNG: &[u8] = &[
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00,
        0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xde, 0x00, 0x00, 0x00,
        0x0c, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0x00, 0x00, 0x03, 0x01, 0x01, 0x00, 0xc9,
        0xfe, 0x92, 0xef, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ];

    fn capture_png(d: &Device, text: &str) -> String {
        let id = crate::files::stage_bytes(&d.dir, "pixel.png", PIXEL_PNG).unwrap().id;
        feed::capture(&d.db.lock().unwrap(), &d.dir, text, std::slice::from_ref(&id), None, T0).unwrap();
        id
    }

    fn flag(d: &Device, column: &str, id: &str) -> bool {
        d.db.lock()
            .unwrap()
            .query_row(&format!("SELECT {column} FROM attachments WHERE id = ?1"), [id], |r| r.get(0))
            .unwrap()
    }

    #[tokio::test]
    async fn an_attachment_captured_offline_uploads_after_a_relaunch() {
        let mut server = TestServer::new();
        let a = device(&server, &server.secret);
        let id = capture_png(&a, "");
        assert!(matches!(sync(&a).await, Err(SyncError::Failed(_))));

        let a = reopen(a);
        server.start();
        assert_eq!(sync(&a).await, Ok(true));
        assert!(flag(&a, "uploaded", &id));
        assert!(flag(&a, "has_thumbnail", &id), "the pull after uploading didn't bring the thumbnail");
        assert!(!feed::list_items(&a.db.lock().unwrap(), &View::All, None, 0).unwrap()[0].pending);

        let b = device(&server, &server.secret);
        sync(&b).await.unwrap();
        assert!(flag(&b, "uploaded", &id));
    }

    #[tokio::test]
    async fn an_attachment_removed_on_the_server_stops_uploading() {
        let mut server = TestServer::new();
        server.start();
        let a = device(&server, &server.secret);
        let id = capture_png(&a, "photo");
        let (op, item_id, device_id): (String, String, String) = a
            .db
            .lock()
            .unwrap()
            .query_row("SELECT op, json_extract(op, '$.item_id'), (SELECT device_id FROM device) FROM outbox", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap();
        let remove = serde_json::json!({"id": uuid::Uuid::new_v4().to_string(), "type": "RemoveAttachment",
            "at": "2025-10-09T08:53:21Z", "item_id": item_id, "attachment_id": id});
        let body = serde_json::json!({"device_id": device_id,
            "ops": [serde_json::from_str::<serde_json::Value>(&op).unwrap(), remove]});
        let res = client().post(format!("{}/sync/push", server.url)).bearer_auth(&server.secret).json(&body).send().await.unwrap();
        assert!(res.status().is_success());
        a.db.lock().unwrap().execute("DELETE FROM outbox", []).unwrap();

        assert_eq!(upload_pending(&a, &server.url, &server.secret).await, Ok(true));
        assert!(flag(&a, "uploaded", &id), "a 410 must stop the retries");
    }

    #[tokio::test]
    async fn another_device_gets_the_thumbnail_and_the_exact_file() {
        let mut server = TestServer::new();
        server.start();
        let a = device(&server, &server.secret);
        let id = capture_png(&a, "photo");
        sync(&a).await.unwrap();
        let b = device(&server, &server.secret);
        sync(&b).await.unwrap();

        crate::cache::prefetch_thumbnails(&b, T0).await;
        let thumb = crate::cache::thumbnail(&b, &id, T0).await.unwrap();
        assert!(thumb.starts_with(b.dir.join("thumbnails")));
        assert_eq!(&std::fs::read(&thumb).unwrap()[..2], [0xff, 0xd8], "not a JPEG");
        let prefetched: i64 = b
            .db
            .lock()
            .unwrap()
            .query_row("SELECT count(*) FROM cached_files WHERE kind = 'thumbnail'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(prefetched, 1);

        let full = crate::cache::file(&b, &id, T0).await.unwrap();
        assert_eq!(full, b.dir.join("files").join(&id).join("pixel.png"));
        assert_eq!(std::fs::read(full).unwrap(), PIXEL_PNG);
    }

    #[tokio::test]
    async fn a_slow_upload_that_keeps_moving_finishes() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            use std::io::{Read, Write};
            let (mut s, _) = listener.accept().unwrap();
            let mut head = Vec::new();
            while !head.ends_with(b"\r\n\r\n") {
                let mut byte = [0; 1];
                s.read_exact(&mut byte).unwrap();
                head.push(byte[0]);
            }
            let head = String::from_utf8(head).unwrap().to_lowercase();
            let len: usize = head.split("content-length: ").nth(1).unwrap().split("\r\n").next().unwrap().parse().unwrap();
            let (mut got, mut buf) = (0, vec![0; 512 * 1024]);
            while got < len {
                got += s.read(&mut buf).unwrap();
                std::thread::sleep(Duration::from_millis(100));
            }
            s.write_all(b"HTTP/1.1 204 No Content\r\nconnection: close\r\n\r\n").unwrap();
        });
        let a = device_at(&url, "s");
        let id = crate::files::stage_bytes(&a.dir, "big.bin", &vec![0; 16 << 20]).unwrap().id;
        feed::capture(&a.db.lock().unwrap(), &a.dir, "", std::slice::from_ref(&id), None, T0).unwrap();

        let started = std::time::Instant::now();
        assert_eq!(upload_pending(&a, &url, "s").await, Ok(true));
        assert!(started.elapsed() > IDLE_TIMEOUT, "the upload was too fast to prove anything");
    }

    /// A stand-in Server that reads one request's headers, sends `reply`, then goes silent.
    fn stall(reply: &'static [u8]) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut head = Vec::new();
            while !head.ends_with(b"\r\n\r\n") {
                let mut byte = [0; 1];
                std::io::Read::read_exact(&mut s, &mut byte).unwrap();
                head.push(byte[0]);
            }
            std::io::Write::write_all(&mut s, reply).unwrap();
            std::thread::sleep(Duration::from_secs(30));
        });
        url
    }

    #[tokio::test]
    async fn a_stalled_upload_fails() {
        let url = stall(b"");
        let a = device_at(&url, "s");
        let id = crate::files::stage_bytes(&a.dir, "big.bin", &vec![0; 16 << 20]).unwrap().id;
        feed::capture(&a.db.lock().unwrap(), &a.dir, "", std::slice::from_ref(&id), None, T0).unwrap();
        let res = tokio::time::timeout(IDLE_TIMEOUT * 3, upload_pending(&a, &url, "s")).await.expect("never gave up");
        assert!(matches!(res, Err(SyncError::Failed(e)) if e.contains("stalled")));
    }

    /// A stand-in Server that reads one request's headers, sends `head` then `body`, and closes.
    fn answer(head: &'static str, body: Vec<u8>) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut head_in = Vec::new();
            while !head_in.ends_with(b"\r\n\r\n") {
                let mut byte = [0; 1];
                std::io::Read::read_exact(&mut s, &mut byte).unwrap();
                head_in.push(byte[0]);
            }
            let _ = std::io::Write::write_all(&mut s, head.as_bytes());
            let _ = std::io::Write::write_all(&mut s, &body);
        });
        url
    }

    fn uploaded_attachment(d: &Device, size_bytes: usize) -> String {
        let id = uuid::Uuid::new_v4().to_string();
        d.db.lock()
            .unwrap()
            .execute_batch(&format!(
                "INSERT INTO items (id, capture_time) VALUES ('i', {T0});
                 INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
                 VALUES ('{id}', 'i', 'r.bin', 'application/octet-stream', {size_bytes}, 1, 1);"
            ))
            .unwrap();
        id
    }

    fn cached_count(d: &Device) -> i64 {
        d.db.lock().unwrap().query_row("SELECT count(*) FROM cached_files", [], |r| r.get(0)).unwrap()
    }

    const CLOSE: &str = "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n";

    #[tokio::test]
    async fn a_file_of_exactly_its_size_downloads() {
        let url = answer(CLOSE, b"abcd".to_vec());
        let b = device_at(&url, "s");
        let id = uploaded_attachment(&b, 4);
        let path = crate::cache::file(&b, &id, T0).await.unwrap();
        assert_eq!(std::fs::read(path).unwrap(), b"abcd");
    }

    #[tokio::test]
    async fn a_file_longer_than_its_size_stops_and_leaves_nothing() {
        let url = answer(CLOSE, b"abcde".to_vec());
        let b = device_at(&url, "s");
        let id = uploaded_attachment(&b, 4);
        assert_eq!(crate::cache::file(&b, &id, T0).await.unwrap_err(), "The Server sent more than expected");
        let left = std::fs::read_dir(b.dir.join("files").join(&id)).map(|d| d.count()).unwrap_or(0);
        assert_eq!(left, 0, "the partial download stayed behind");
        assert_eq!(cached_count(&b), 0);
    }

    #[tokio::test]
    async fn a_short_file_is_not_cached() {
        let url = answer(CLOSE, b"abc".to_vec());
        let b = device_at(&url, "s");
        let id = uploaded_attachment(&b, 4);
        assert_eq!(crate::cache::file(&b, &id, T0).await.unwrap_err(), "The download was incomplete");
        assert_eq!(cached_count(&b), 0);
    }

    #[tokio::test]
    async fn an_oversized_content_length_fails_without_waiting_for_the_body() {
        let url = stall(b"HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\n");
        let b = device_at(&url, "s");
        let id = uploaded_attachment(&b, 4);
        let res = tokio::time::timeout(Duration::from_secs(2), crate::cache::file(&b, &id, T0)).await.expect("waited for the body");
        assert_eq!(res.unwrap_err(), "The Server sent more than expected");
    }

    #[tokio::test]
    async fn a_file_the_server_claims_is_over_the_limit_is_never_downloaded() {
        let url = stall(b"HTTP/1.1 200 OK\r\n\r\n");
        let b = device_at(&url, "s");
        let id = uploaded_attachment(&b, (crate::files::MAX_ATTACHMENT_BYTES + 1) as usize);
        let res = tokio::time::timeout(Duration::from_secs(2), crate::cache::file(&b, &id, T0)).await.expect("started downloading");
        assert_eq!(res.unwrap_err(), "The Server sent more than expected");
    }

    #[tokio::test]
    async fn a_thumbnail_may_be_up_to_1_mib() {
        let max = crate::cache::MAX_THUMBNAIL_BYTES as usize;
        let url = answer(CLOSE, vec![0; max]);
        let b = device_at(&url, "s");
        let id = uploaded_attachment(&b, 10);
        assert!(crate::cache::thumbnail(&b, &id, T0).await.is_ok());

        let url = answer(CLOSE, vec![0; max + 1]);
        let c = device_at(&url, "s");
        let id = uploaded_attachment(&c, 10);
        assert_eq!(crate::cache::thumbnail(&c, &id, T0).await.unwrap_err(), "The Server sent more than expected");
    }

    #[tokio::test]
    async fn a_stalled_download_fails() {
        let url = stall(b"HTTP/1.1 200 OK\r\ncontent-length: 1000\r\n\r\npartial");
        let b = device_at(&url, "s");
        let id = uuid::Uuid::new_v4().to_string();
        b.db.lock().unwrap().execute_batch(&format!(
            "INSERT INTO items (id, capture_time) VALUES ('i', 1);
             INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES ('{id}', 'i', 'r.pdf', 'application/pdf', 1000, 1, 0);"
        )).unwrap();
        let res = tokio::time::timeout(IDLE_TIMEOUT * 3, crate::cache::file(&b, &id, T0)).await.expect("never gave up");
        assert_eq!(res.unwrap_err(), "Can't download while offline");
    }

    #[tokio::test]
    async fn a_file_with_a_255_byte_name_downloads() {
        let mut server = TestServer::new();
        server.start();
        let a = device(&server, &server.secret);
        let name = format!("{}.png", "x".repeat(251));
        let id = crate::files::stage_bytes(&a.dir, &name, PIXEL_PNG).unwrap().id;
        feed::capture(&a.db.lock().unwrap(), &a.dir, "", std::slice::from_ref(&id), None, T0).unwrap();
        sync(&a).await.unwrap();
        let b = device(&server, &server.secret);
        sync(&b).await.unwrap();

        let full = crate::cache::file(&b, &id, T0).await.unwrap();
        assert_eq!(full.file_name().unwrap().len(), 255);
        assert_eq!(std::fs::read(full).unwrap(), PIXEL_PNG);
    }

    #[tokio::test]
    async fn pulled_items_are_reported_even_when_an_upload_fails() {
        let mut server = TestServer::new();
        server.start();
        let b = device(&server, &server.secret);
        feed::capture(&b.db.lock().unwrap(), &b.dir, "from b", &[], None, T0).unwrap();
        sync(&b).await.unwrap();
        let a = device(&server, &server.secret);
        let id = capture_png(&a, "photo");
        std::fs::File::options().write(true).open(a.dir.join("files").join(&id).join("pixel.png")).unwrap().set_len(10).unwrap();

        assert_eq!(sync(&a).await, Ok(true));
        assert!(texts(&a).contains(&"from b".to_string()));
        assert!(matches!(sync(&a).await, Err(SyncError::Failed(_))), "the failed upload was never reported");
    }

    const SECOND: i64 = 1_000_000;

    fn place(d: &Device, item_id: &str) -> (Option<String>, bool) {
        d.db.lock()
            .unwrap()
            .query_row("SELECT topic_id, deleted_at IS NOT NULL FROM items WHERE id = ?1", [item_id], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .unwrap()
    }

    fn topic_names(d: &Device) -> Vec<(String, bool)> {
        topics::list(&d.db.lock().unwrap()).unwrap().into_iter().map(|t| (t.name, t.archived)).collect()
    }

    fn only_item(d: &Device) -> String {
        feed::list_items(&d.db.lock().unwrap(), &View::All, None, 0).unwrap()[0].id.clone()
    }

    #[tokio::test]
    async fn a_move_into_a_topic_archived_elsewhere_comes_back() {
        let mut server = TestServer::new();
        server.start();
        let (a, b) = (device(&server, &server.secret), device(&server, &server.secret));
        let gym = topics::create(&a.db.lock().unwrap(), "Gym", T0).unwrap().id;
        feed::capture(&a.db.lock().unwrap(), &a.dir, "squat 100", &[], None, T0 + SECOND).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();
        let item = only_item(&a);

        feed::move_item(&a.db.lock().unwrap(), &item, Some(&gym), T0 + 10 * SECOND).unwrap();
        topics::set_archived(&b.db.lock().unwrap(), &gym, true, T0 + 20 * SECOND).unwrap();
        sync(&b).await.unwrap();
        sync(&a).await.unwrap();

        assert_eq!(place(&a, &item), (None, false), "A still shows the move the Server rejected");
        assert_eq!(topic_names(&a), [("Gym".to_string(), true)]);
        let notice = SyncNotice {
            kind: "move",
            item_id: item,
            label: "squat 100".into(),
            topic: Some("Gym".into()),
            topic_state: Some("archived"),
            place: None,
            topic_id: Some(gym),
        };
        assert_eq!(*a.notices.lock().unwrap(), [notice]);
    }

    #[tokio::test]
    async fn a_capture_into_a_topic_archived_elsewhere_lands_in_the_inbox_with_a_notice() {
        let mut server = TestServer::new();
        server.start();
        let (a, b) = (device(&server, &server.secret), device(&server, &server.secret));
        let gym = topics::create(&a.db.lock().unwrap(), "Gym", T0).unwrap().id;
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();

        topics::set_archived(&b.db.lock().unwrap(), &gym, true, T0 + 10 * SECOND).unwrap();
        sync(&b).await.unwrap();
        feed::capture(&a.db.lock().unwrap(), &a.dir, "squat 100", &[], Some(&gym), T0 + 20 * SECOND).unwrap();
        sync(&a).await.unwrap();

        let item = only_item(&a);
        let notice = SyncNotice {
            kind: "inbox",
            item_id: item.clone(),
            label: "squat 100".into(),
            topic: Some("Gym".into()),
            topic_state: Some("archived"),
            place: None,
            topic_id: Some(gym),
        };
        assert_eq!(*a.notices.lock().unwrap(), [notice]);
        assert_eq!(place(&a, &item), (None, false));
    }

    fn conflict(d: &Device, item_id: &str) -> Option<(Option<String>, bool)> {
        d.db.lock()
            .unwrap()
            .query_row("SELECT text, mine FROM conflicts WHERE item_id = ?1", [item_id], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()
            .unwrap()
    }

    fn item_text(d: &Device, item_id: &str) -> Option<String> {
        d.db.lock().unwrap().query_row("SELECT text FROM items WHERE id = ?1", [item_id], |r| r.get(0)).unwrap()
    }

    fn is_pending(d: &Device) -> bool {
        feed::list_items(&d.db.lock().unwrap(), &View::All, None, 0).unwrap()[0].pending
    }

    async fn two_devices_on_one_item(server: &mut TestServer) -> (Device, Device, String) {
        server.start();
        let (a, b) = (device(server, &server.secret), device(server, &server.secret));
        feed::capture(&a.db.lock().unwrap(), &a.dir, "shoes", &[], None, T0).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();
        let item = only_item(&a);
        (a, b, item)
    }

    fn edit(d: &Device, item: &str, text: &str, base_rev: i64, at: i64) {
        feed::edit_item(&d.db.lock().unwrap(), &d.dir, item, text, &[], &[], base_rev, at).unwrap();
    }

    #[tokio::test]
    async fn an_older_overlapping_edit_is_kept_as_mine() {
        let mut server = TestServer::new();
        let (a, b, item) = two_devices_on_one_item(&mut server).await;
        edit(&b, &item, "theirs", 0, T0 + 10 * SECOND);
        sync(&b).await.unwrap();
        edit(&a, &item, "mine", 0, T0 + 5 * SECOND);
        sync(&a).await.unwrap();

        assert_eq!(item_text(&a, &item).as_deref(), Some("theirs"));
        assert_eq!(conflict(&a, &item), Some((Some("mine".into()), true)));
        assert!(!is_pending(&a));
    }

    #[tokio::test]
    async fn a_newer_overlapping_edit_keeps_theirs() {
        let mut server = TestServer::new();
        let (a, b, item) = two_devices_on_one_item(&mut server).await;
        edit(&b, &item, "theirs", 0, T0 + 5 * SECOND);
        sync(&b).await.unwrap();
        edit(&a, &item, "mine", 0, T0 + 10 * SECOND);
        sync(&a).await.unwrap();

        assert_eq!(item_text(&a, &item).as_deref(), Some("mine"));
        assert_eq!(conflict(&a, &item), Some((Some("theirs".into()), false)));
        sync(&b).await.unwrap();
        assert_eq!(item_text(&b, &item).as_deref(), Some("mine"));
        assert_eq!(conflict(&b, &item), None);
    }

    #[tokio::test]
    async fn a_slow_clock_edit_from_the_current_text_applies() {
        let mut server = TestServer::new();
        let (a, b, item) = two_devices_on_one_item(&mut server).await;
        edit(&b, &item, "theirs", 0, T0 + 10 * SECOND);
        sync(&b).await.unwrap();
        sync(&a).await.unwrap();
        let base = feed::list_items(&a.db.lock().unwrap(), &View::All, None, 0).unwrap()[0].edit_base;
        assert_eq!(base, 1);
        edit(&a, &item, "mine", base, T0 + 5 * SECOND);
        sync(&a).await.unwrap();

        assert_eq!(conflict(&a, &item), None);
        sync(&b).await.unwrap();
        assert_eq!(item_text(&b, &item).as_deref(), Some("mine"));
    }

    type PushReply = fn(&serde_json::Value) -> serde_json::Value;

    fn fake_server(push_reply: PushReply, pull_status: u16) -> (String, Arc<std::sync::atomic::AtomicUsize>) {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!("http://{}", listener.local_addr().unwrap());
        let puts = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let counted = puts.clone();
        std::thread::spawn(move || {
            for mut stream in listener.incoming().flatten() {
                let mut raw = Vec::new();
                let mut buf = [0; 4096];
                let (head_len, body_len) = loop {
                    let n = std::io::Read::read(&mut stream, &mut buf).unwrap();
                    raw.extend_from_slice(&buf[..n]);
                    if let Some(end) = raw.windows(4).position(|w| w == b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&raw[..end]).to_lowercase();
                        let len = head
                            .lines()
                            .find_map(|l| l.strip_prefix("content-length:"))
                            .map_or(0, |v| v.trim().parse().unwrap());
                        break (end + 4, len);
                    }
                };
                while raw.len() < head_len + body_len {
                    let n = std::io::Read::read(&mut stream, &mut buf).unwrap();
                    raw.extend_from_slice(&buf[..n]);
                }
                let request_line = String::from_utf8_lossy(&raw).lines().next().unwrap().to_string();
                let (status, body) = if request_line.starts_with("POST /sync/push") {
                    let sent: serde_json::Value = serde_json::from_slice(&raw[head_len..]).unwrap();
                    (200, push_reply(&sent).to_string())
                } else if request_line.starts_with("GET /sync/pull") {
                    let empty = r#"{"items":[],"topics":[],"tombstones":[],"cursor":0,"has_more":false}"#;
                    (pull_status, empty.to_string())
                } else {
                    counted.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    (204, String::new())
                };
                let reply = format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                    body.len()
                );
                let _ = std::io::Write::write_all(&mut stream, reply.as_bytes());
            }
        });
        (url, puts)
    }

    fn answers(request: &serde_json::Value, replies: &[(&str, &str)]) -> serde_json::Value {
        let ops = request["ops"].as_array().unwrap();
        assert_eq!(ops.len(), replies.len());
        let results: Vec<_> = ops
            .iter()
            .zip(replies)
            .map(|(op, (status, reason))| serde_json::json!({"op_id": op["id"], "status": status, "reason": reason, "text": null}))
            .collect();
        serde_json::json!({"results": results})
    }

    fn sync_error(d: &Device, item_id: &str) -> Option<String> {
        d.db.lock().unwrap().query_row("SELECT sync_error FROM items WHERE id = ?1", [item_id], |r| r.get(0)).unwrap()
    }

    #[tokio::test]
    async fn a_refused_capture_is_marked_and_stops_uploading() {
        let (url, puts) = fake_server(|req| answers(req, &[("rejected", "invalid")]), 200);
        let a = device_at(&url, "secret");
        capture_png(&a, "photo");
        let item = only_item(&a);
        assert!(is_pending(&a));

        sync(&a).await.unwrap();
        sync(&a).await.unwrap();

        assert_eq!(sync_error(&a, &item).as_deref(), Some("invalid"));
        assert!(!is_pending(&a));
        assert_eq!(puts.load(std::sync::atomic::Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn ops_on_a_refused_capture_are_silent() {
        let (url, _) = fake_server(|req| answers(req, &[("rejected", "invalid"), ("rejected", "not_found")]), 200);
        let a = device_at(&url, "secret");
        feed::capture(&a.db.lock().unwrap(), &a.dir, "shoes", &[], None, T0).unwrap();
        let item = only_item(&a);
        edit(&a, &item, "shoes, size 9", 0, T0 + SECOND);

        sync(&a).await.unwrap();

        assert_eq!(sync_error(&a, &item).as_deref(), Some("invalid"));
        assert!(a.notices.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn results_are_kept_when_the_pull_fails() {
        let (url, _) = fake_server(|req| answers(req, &[("rejected", "superseded")]), 500);
        let a = device_at(&url, "secret");
        a.db.lock()
            .unwrap()
            .execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'shoes', ?1)", [T0])
            .unwrap();
        edit(&a, "i", "mine", 0, T0 + SECOND);

        assert!(matches!(sync(&a).await, Err(SyncError::Failed(_))));

        assert_eq!(conflict(&a, "i"), Some((Some("mine".into()), true)));
        assert_eq!(count(&a, "outbox"), 0);
    }

    #[tokio::test]
    async fn topic_changes_reach_another_device() {
        let mut server = TestServer::new();
        server.start();
        let (a, b) = (device(&server, &server.secret), device(&server, &server.secret));
        let id = topics::create(&a.db.lock().unwrap(), "Gym", T0).unwrap().id;
        topics::rename(&a.db.lock().unwrap(), &id, "Lifting", T0 + SECOND).unwrap();
        topics::set_archived(&a.db.lock().unwrap(), &id, true, T0 + 2 * SECOND).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();
        assert_eq!(topic_names(&b), [("Lifting".to_string(), true)]);
    }

    #[tokio::test]
    async fn deleting_a_topic_keeps_the_chosen_items_on_both_devices() {
        let mut server = TestServer::new();
        server.start();
        let (a, b) = (device(&server, &server.secret), device(&server, &server.secret));
        let gym = topics::create(&a.db.lock().unwrap(), "Gym", T0).unwrap().id;
        feed::capture(&a.db.lock().unwrap(), &a.dir, "keep me", &[], Some(&gym), T0 + SECOND).unwrap();
        feed::capture(&a.db.lock().unwrap(), &a.dir, "bin me", &[], Some(&gym), T0 + 2 * SECOND).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();
        let items = feed::list_items(&a.db.lock().unwrap(), &View::All, None, 0).unwrap();
        let (binned, kept) = (items[0].id.clone(), items[1].id.clone());

        topics::delete(&a.db.lock().unwrap(), &gym, &Keep::Only { ids: vec![kept.clone()] }, T0 + 3 * SECOND).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();

        for d in [&a, &b] {
            assert_eq!(place(d, &kept), (None, false));
            assert_eq!(place(d, &binned), (None, true));
            assert!(topic_names(d).is_empty());
        }
    }

    #[tokio::test]
    async fn a_capture_into_a_topic_arrives_filed() {
        let mut server = TestServer::new();
        server.start();
        let (a, b) = (device(&server, &server.secret), device(&server, &server.secret));
        let gym = topics::create(&a.db.lock().unwrap(), "Gym", T0).unwrap().id;
        feed::capture(&a.db.lock().unwrap(), &a.dir, "squat 100", &[], Some(&gym), T0 + SECOND).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();
        assert_eq!(place(&b, &only_item(&b)), (Some(gym), false));
    }

    #[tokio::test]
    async fn the_same_name_created_offline_on_two_devices_gets_a_number() {
        let mut server = TestServer::new();
        server.start();
        let (a, b) = (device(&server, &server.secret), device(&server, &server.secret));
        topics::create(&a.db.lock().unwrap(), "Books", T0).unwrap();
        topics::create(&b.db.lock().unwrap(), "Books", T0 + SECOND).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();
        sync(&a).await.unwrap();
        for d in [&a, &b] {
            let mut names: Vec<String> = topic_names(d).into_iter().map(|(n, _)| n).collect();
            names.sort();
            assert_eq!(names, ["Books", "Books (1)"]);
        }
    }

    fn now() -> i64 {
        chrono::Utc::now().timestamp_micros()
    }

    #[tokio::test]
    async fn an_edit_reaches_another_device() {
        let mut server = TestServer::new();
        server.start();
        let (a, b) = (device(&server, &server.secret), device(&server, &server.secret));
        let first = capture_png(&a, "receipt");
        sync(&a).await.unwrap();
        let item = only_item(&a);
        let second = crate::files::stage_bytes(&a.dir, "second.png", PIXEL_PNG).unwrap().id;
        feed::edit_item(
            &a.db.lock().unwrap(),
            &a.dir,
            &item,
            "receipt, kept",
            std::slice::from_ref(&second),
            std::slice::from_ref(&first),
            0,
            T0 + SECOND,
        )
        .unwrap();
        sync(&a).await.unwrap();
        assert!(flag(&a, "uploaded", &second));

        sync(&b).await.unwrap();
        let got = &feed::list_items(&b.db.lock().unwrap(), &View::All, None, now()).unwrap()[0];
        assert_eq!(got.text.as_deref(), Some("receipt, kept"));
        assert_eq!(got.attachments.iter().map(|a| a.id.clone()).collect::<Vec<_>>(), [second]);
    }

    #[tokio::test]
    async fn an_emptied_item_waits_in_trash_until_the_servers_deadline_and_comes_back_whole() {
        let mut server = TestServer::new();
        server.start();
        let (a, b) = (device(&server, &server.secret), device(&server, &server.secret));
        feed::capture(&a.db.lock().unwrap(), &a.dir, "squat 100", &[], None, T0).unwrap();
        sync(&a).await.unwrap();
        let item = only_item(&a);

        let before = now();
        assert!(feed::edit_item(&a.db.lock().unwrap(), &a.dir, &item, "", &[], &[], 0, T0 + SECOND).unwrap().trashed);
        sync(&a).await.unwrap();
        let after = now();
        let trash = feed::list_items(&a.db.lock().unwrap(), &View::Trash, None, now()).unwrap();
        let purge_at = trash[0].purge_at_us.expect("the pull brought the Server's deadline");
        let thirty_days = 30 * 24 * 3600 * SECOND;
        assert!((before - SECOND + thirty_days..=after + SECOND + thirty_days).contains(&purge_at), "{purge_at}");

        feed::set_trashed(&a.db.lock().unwrap(), &item, false, T0 + 2 * SECOND).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();
        assert_eq!(texts(&b), ["squat 100"]);
    }

    #[tokio::test]
    async fn an_edit_started_before_a_pull_reports_the_overlap() {
        let mut server = TestServer::new();
        server.start();
        let (a, b) = (device(&server, &server.secret), device(&server, &server.secret));
        feed::capture(&a.db.lock().unwrap(), &a.dir, "shoes", &[], None, T0).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();
        let item = only_item(&a);
        let base = feed::list_items(&a.db.lock().unwrap(), &View::All, None, 0).unwrap()[0].edit_base;
        assert_eq!(base, 0);

        feed::edit_item(&b.db.lock().unwrap(), &b.dir, &item, "shoes, size 9", &[], &[], 0, T0 + 10 * SECOND).unwrap();
        sync(&b).await.unwrap();
        sync(&a).await.unwrap();
        feed::edit_item(&a.db.lock().unwrap(), &a.dir, &item, "shoes, size 10", &[], &[], base, T0 + 20 * SECOND).unwrap();
        sync(&a).await.unwrap();

        let (text, mine): (Option<String>, bool) = a
            .db
            .lock()
            .unwrap()
            .query_row("SELECT text, mine FROM conflicts WHERE item_id = ?1", [&item], |r| Ok((r.get(0)?, r.get(1)?)))
            .unwrap();
        assert_eq!((text.as_deref(), mine), (Some("shoes, size 9"), false));
    }

    #[tokio::test]
    async fn an_edit_made_after_a_trash_elsewhere_brings_the_item_back() {
        let mut server = TestServer::new();
        server.start();
        let (a, b) = (device(&server, &server.secret), device(&server, &server.secret));
        feed::capture(&a.db.lock().unwrap(), &a.dir, "shoes", &[], None, T0).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();
        let item = only_item(&a);

        feed::set_trashed(&b.db.lock().unwrap(), &item, true, T0 + 10 * SECOND).unwrap();
        sync(&b).await.unwrap();
        feed::edit_item(&a.db.lock().unwrap(), &a.dir, &item, "shoes, size 10.5", &[], &[], 0, T0 + 20 * SECOND).unwrap();
        sync(&a).await.unwrap();
        sync(&b).await.unwrap();
        assert_eq!(place(&b, &item), (None, false));
        assert_eq!(texts(&b), ["shoes, size 10.5"]);
    }
}
