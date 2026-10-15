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
    #[allow(dead_code)]
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
