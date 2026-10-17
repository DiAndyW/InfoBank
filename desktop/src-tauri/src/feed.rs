use std::path::Path;

use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::files;
use crate::ops;

// The Server's limit, so the Server never rejects a Capture.
const MAX_ITEM_TEXT_BYTES: usize = 1 << 20;
const PAGE_SIZE: i64 = 100;

#[derive(Serialize)]
pub struct FeedItem {
    pub id: String,
    pub text: Option<String>,
    pub capture_time_us: i64,
    pub topic_id: Option<String>,
    pub pending: bool,
    pub attachments: Vec<FeedAttachment>,
}

#[derive(Serialize)]
pub struct FeedAttachment {
    pub id: String,
    pub filename: String,
    pub mime_type: String,
    pub size_bytes: i64,
    pub has_thumbnail: bool,
    pub runnable: bool,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum View {
    All,
    Inbox,
    Topic { id: String },
}

#[derive(Deserialize)]
pub struct Before {
    pub capture_time_us: i64,
    pub id: String,
}

pub fn capture(
    conn: &Connection,
    dir: &Path,
    text: &str,
    attachment_ids: &[String],
    topic_id: Option<&str>,
    now_us: i64,
) -> Result<(), String> {
    let text = text.trim();
    if text.is_empty() && attachment_ids.is_empty() {
        return Err("Write something first".into());
    }
    if text.len() > MAX_ITEM_TEXT_BYTES {
        return Err("That's too long to save (1 MB max)".into());
    }
    if text.contains('\0') {
        return Err("That text contains a character that can't be saved".into());
    }
    if let Some(id) = topic_id {
        crate::topics::require_open(conn, id)?;
    }
    let mut attachments = Vec::new();
    for id in attachment_ids {
        let id = uuid::Uuid::parse_str(id).map_err(|_| "An attachment is missing; add it again")?.to_string();
        let (filename, size_bytes) = files::staged_file(dir, &id)?;
        if size_bytes > files::MAX_ATTACHMENT_BYTES {
            return Err(format!("{filename} is over 100 MB"));
        }
        let mime_type = files::mime_type(&filename);
        attachments.push(ops::NewAttachment { id, filename, mime_type, size_bytes: size_bytes as i64 });
    }
    let text = (!text.is_empty()).then(|| text.to_string());
    let item_id = uuid::Uuid::new_v4().to_string();

    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    tx.execute(
        "INSERT INTO items (id, topic_id, text, capture_time) VALUES (?1, ?2, ?3, ?4)",
        (&item_id, topic_id, &text, now_us),
    )
    .map_err(|e| e.to_string())?;
    for a in &attachments {
        tx.execute(
            "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, 0)",
            (&a.id, &item_id, &a.filename, &a.mime_type, a.size_bytes),
        )
        .map_err(|e| e.to_string())?;
        // The pinned local copy: eviction skips it until the Server has the file.
        tx.execute(
            "INSERT INTO cached_files (attachment_id, kind, path, size_bytes, last_used_at) VALUES (?1, 'file', ?2, ?3, ?4)",
            (&a.id, format!("files/{}/{}", a.id, a.filename), a.size_bytes, now_us),
        )
        .map_err(|e| e.to_string())?;
    }
    ops::queue(&tx, ops::Op::CaptureItem { item_id, topic_id: topic_id.map(String::from), text, attachments }, now_us)?;
    tx.commit().map_err(|e| e.to_string())
}

pub fn move_item(conn: &Connection, item_id: &str, topic_id: Option<&str>, now_us: i64) -> Result<(), String> {
    let current: Option<String> = conn
        .query_row("SELECT topic_id FROM items WHERE id = ?1 AND deleted_at IS NULL", [item_id], |r| r.get(0))
        .optional()
        .map_err(|e| e.to_string())?
        .ok_or("That Item no longer exists")?;
    if current.as_deref() == topic_id {
        return Ok(());
    }
    if let Some(id) = topic_id {
        crate::topics::require_open(conn, id)?;
    }
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    ops::queue(&tx, ops::Op::MoveItem { item_id: item_id.into(), topic_id: topic_id.map(String::from) }, now_us)?;
    tx.commit().map_err(|e| e.to_string())
}

/// Newest first, at most PAGE_SIZE, Trash excluded. `before` continues from the last Item of the previous page.
pub fn list_items(conn: &Connection, view: &View, before: Option<&Before>) -> rusqlite::Result<Vec<FeedItem>> {
    let (kind, topic) = match view {
        View::All => ("all", None),
        View::Inbox => ("inbox", None),
        View::Topic { id } => ("topic", Some(id.as_str())),
    };
    let mut stmt = conn.prepare(
        "SELECT id, text, capture_time, topic_id,
                EXISTS (SELECT 1 FROM outbox WHERE json_extract(op, '$.item_id') = items.id)
                OR EXISTS (SELECT 1 FROM attachments a JOIN cached_files c ON c.attachment_id = a.id AND c.kind = 'file'
                           WHERE a.item_id = items.id AND a.uploaded = 0)
         FROM items
         WHERE deleted_at IS NULL
           AND CASE ?1 WHEN 'all' THEN 1 WHEN 'inbox' THEN topic_id IS NULL ELSE topic_id = ?2 END
           AND (?3 IS NULL OR (capture_time, id) < (?3, ?4))
         ORDER BY capture_time DESC, id DESC
         LIMIT ?5",
    )?;
    let mut items: Vec<FeedItem> = stmt
        .query_map(
            (kind, topic, before.map(|b| b.capture_time_us), before.map(|b| b.id.as_str()), PAGE_SIZE),
            |r| {
                Ok(FeedItem {
                    id: r.get(0)?,
                    text: r.get(1)?,
                    capture_time_us: r.get(2)?,
                    topic_id: r.get(3)?,
                    pending: r.get(4)?,
                    attachments: Vec::new(),
                })
            },
        )?
        .collect::<rusqlite::Result<_>>()?;

    let ids = serde_json::to_string(&items.iter().map(|i| &i.id).collect::<Vec<_>>()).expect("strings serialize");
    let mut stmt = conn.prepare(
        "SELECT item_id, id, filename, mime_type, size_bytes, has_thumbnail FROM attachments
         WHERE item_id IN (SELECT value FROM json_each(?1)) ORDER BY rowid",
    )?;
    let mut rows = stmt.query([ids])?;
    while let Some(r) = rows.next()? {
        let item_id: String = r.get(0)?;
        if let Some(item) = items.iter_mut().find(|i| i.id == item_id) {
            let filename: String = r.get(2)?;
            item.attachments.push(FeedAttachment {
                id: r.get(1)?,
                mime_type: r.get(3)?,
                size_bytes: r.get(4)?,
                has_thumbnail: r.get(5)?,
                runnable: files::runnable(&filename),
                filename,
            });
        }
    }
    Ok(items)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        (dir, conn)
    }

    fn count(conn: &Connection, table: &str) -> i64 {
        conn.query_row(&format!("SELECT count(*) FROM {table}"), [], |r| r.get(0)).unwrap()
    }

    #[test]
    fn capture_writes_the_item_and_its_op_together() {
        let (d, conn) = fresh();
        capture(&conn, d.path(), "  hello\n", &[], None, 1_760_000_000_123_456).unwrap();

        let items = list_items(&conn, &View::All, None).unwrap();
        assert_eq!(items.len(), 1);
        let it = &items[0];
        assert_eq!(it.text.as_deref(), Some("hello"));
        assert_eq!(it.capture_time_us, 1_760_000_000_123_456);
        assert_eq!(it.topic_id, None);
        assert!(it.pending);

        let op: String = conn.query_row("SELECT op FROM outbox", [], |r| r.get(0)).unwrap();
        let op: serde_json::Value = serde_json::from_str(&op).unwrap();
        assert_eq!(op["type"], "CaptureItem");
        assert_eq!(op["item_id"], it.id.as_str());
        assert_eq!(op["text"], "hello");
        assert_eq!(op["at"], "2025-10-09T08:53:20.123456Z");
        assert_eq!(op["topic_id"], serde_json::Value::Null);
        assert_eq!(op["attachments"], serde_json::json!([]));
        assert!(uuid::Uuid::parse_str(op["id"].as_str().unwrap()).is_ok());
        assert_ne!(op["id"], op["item_id"]);
    }

    #[test]
    fn capture_rejects_text_the_server_would_and_writes_nothing() {
        let (d, conn) = fresh();
        let too_long = "x".repeat(MAX_ITEM_TEXT_BYTES + 1);
        for text in ["", "  \n ", "a\0b", too_long.as_str()] {
            assert!(capture(&conn, d.path(), text, &[], None, 1).is_err(), "accepted {:.20?}", text);
        }
        assert_eq!(count(&conn, "items"), 0);
        assert_eq!(count(&conn, "outbox"), 0);
        // The limit itself is allowed, so the guard above is the byte limit and not something stricter.
        capture(&conn, d.path(), &"x".repeat(MAX_ITEM_TEXT_BYTES), &[], None, 1).unwrap();
    }

    #[test]
    fn views_filter_and_hide_trash() {
        let (_d, conn) = fresh();
        conn.execute_batch(
            "INSERT INTO items (id, text, capture_time) VALUES ('inbox', 'a', 1);
             INSERT INTO items (id, topic_id, text, capture_time) VALUES ('filed', 'T', 'b', 2);
             INSERT INTO items (id, text, capture_time, deleted_at) VALUES ('trashed', 'c', 3, 3);",
        )
        .unwrap();
        let ids = |view: View| -> Vec<String> {
            list_items(&conn, &view, None).unwrap().into_iter().map(|i| i.id).collect()
        };
        assert_eq!(ids(View::All), ["filed", "inbox"]);
        assert_eq!(ids(View::Inbox), ["inbox"]);
        assert_eq!(ids(View::Topic { id: "T".into() }), ["filed"]);
    }

    #[test]
    fn equal_capture_times_page_without_gaps_or_repeats() {
        let (_d, conn) = fresh();
        for i in 0..=PAGE_SIZE {
            conn.execute("INSERT INTO items (id, text, capture_time) VALUES (?1, 'x', 5)", [format!("{i:03}")])
                .unwrap();
        }
        let first = list_items(&conn, &View::All, None).unwrap();
        assert_eq!(first.len(), PAGE_SIZE as usize);
        let last = first.last().unwrap();
        let before = Before { capture_time_us: last.capture_time_us, id: last.id.clone() };
        let second = list_items(&conn, &View::All, Some(&before)).unwrap();

        let mut all: Vec<String> = first.into_iter().chain(second).map(|i| i.id).collect();
        assert_eq!(all.len(), PAGE_SIZE as usize + 1);
        all.sort();
        all.dedup();
        assert_eq!(all.len(), PAGE_SIZE as usize + 1, "an Item was repeated");
    }

    #[test]
    fn an_item_stops_pending_when_its_op_leaves_the_outbox() {
        let (d, conn) = fresh();
        capture(&conn, d.path(), "hi", &[], None, 1).unwrap();
        conn.execute("DELETE FROM outbox", []).unwrap();
        assert!(!list_items(&conn, &View::All, None).unwrap()[0].pending);
    }

    fn png(d: &tempfile::TempDir) -> String {
        crate::files::stage_bytes(d.path(), "scan.png", b"png").unwrap().id
    }

    #[test]
    fn an_attachment_is_captured_with_its_item_in_one_transaction() {
        let (d, conn) = fresh();
        let id = png(&d);
        capture(&conn, d.path(), "  ", std::slice::from_ref(&id), None, 1_760_000_000_000_000).unwrap();

        let item = &list_items(&conn, &View::All, None).unwrap()[0];
        assert_eq!(item.text, None);
        assert!(item.pending);
        let a = &item.attachments[0];
        assert_eq!((a.id.as_str(), a.filename.as_str(), a.mime_type.as_str(), a.size_bytes), (id.as_str(), "scan.png", "image/png", 3));
        assert!(!a.has_thumbnail);

        let path: String = conn
            .query_row("SELECT path FROM cached_files WHERE attachment_id = ?1 AND kind = 'file'", [&id], |r| r.get(0))
            .unwrap();
        assert_eq!(path, format!("files/{id}/scan.png"));
        let op: String = conn.query_row("SELECT op FROM outbox", [], |r| r.get(0)).unwrap();
        let op: serde_json::Value = serde_json::from_str(&op).unwrap();
        assert_eq!(op["text"], serde_json::Value::Null);
        assert_eq!(
            op["attachments"],
            serde_json::json!([{"id": id, "filename": "scan.png", "mime_type": "image/png", "size_bytes": 3}])
        );
    }

    #[test]
    fn a_missing_or_malformed_attachment_writes_nothing() {
        let (d, conn) = fresh();
        let never_staged = uuid::Uuid::new_v4().to_string();
        for bad in ["../files", never_staged.as_str()] {
            assert!(capture(&conn, d.path(), "hi", &[bad.to_string()], None, 1).is_err(), "accepted {bad}");
        }
        assert_eq!(count(&conn, "items"), 0);
        assert_eq!(count(&conn, "outbox"), 0);
        assert!(capture(&conn, d.path(), " ", &[], None, 1).is_err(), "blank with no attachments");
    }

    #[test]
    fn an_item_stays_pending_until_its_files_are_uploaded() {
        let (d, conn) = fresh();
        let id = png(&d);
        capture(&conn, d.path(), "photo", std::slice::from_ref(&id), None, 1).unwrap();
        conn.execute("DELETE FROM outbox", []).unwrap();
        assert!(list_items(&conn, &View::All, None).unwrap()[0].pending, "the file isn't on the Server yet");
        conn.execute("UPDATE attachments SET uploaded = 1", []).unwrap();
        assert!(!list_items(&conn, &View::All, None).unwrap()[0].pending);
    }

    #[test]
    fn the_feed_marks_files_that_can_run_code() {
        let (d, conn) = fresh();
        let ids = ["setup.command", "report.pdf"].map(|n| crate::files::stage_bytes(d.path(), n, b"x").unwrap().id);
        capture(&conn, d.path(), "", &ids, None, 1).unwrap();
        let item = &list_items(&conn, &View::All, None).unwrap()[0];
        assert_eq!(item.attachments.iter().map(|a| a.runnable).collect::<Vec<_>>(), [true, false]);
    }

    fn with_topics(conn: &Connection) {
        conn.execute_batch(
            "INSERT INTO topics (id, name) VALUES ('t', 'Gym');
             INSERT INTO topics (id, name, archived_at) VALUES ('a', 'Old', 1);
             INSERT INTO topics (id, name, deleted_at) VALUES ('d', 'Gone', 1);",
        )
        .unwrap();
    }

    fn outbox_ops(conn: &Connection) -> Vec<serde_json::Value> {
        let mut stmt = conn.prepare("SELECT op FROM outbox ORDER BY seq").unwrap();
        stmt.query_map([], |r| r.get::<_, String>(0)).unwrap().map(|o| serde_json::from_str(&o.unwrap()).unwrap()).collect()
    }

    #[test]
    fn capture_files_the_item_in_the_topic() {
        let (d, conn) = fresh();
        with_topics(&conn);
        capture(&conn, d.path(), "squat 100", &[], Some("t"), 1).unwrap();
        let ids: Vec<String> = list_items(&conn, &View::Topic { id: "t".into() }, None).unwrap().into_iter().map(|i| i.id).collect();
        assert_eq!(ids.len(), 1);
        assert_eq!(outbox_ops(&conn)[0]["topic_id"], "t");
    }

    #[test]
    fn capture_and_move_refuse_topics_that_cant_take_items() {
        let (d, conn) = fresh();
        with_topics(&conn);
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        for id in ["a", "d", "nope"] {
            assert!(capture(&conn, d.path(), "hi", &[], Some(id), 1).is_err(), "captured into {id}");
            assert!(move_item(&conn, "i", Some(id), 1).is_err(), "moved into {id}");
        }
        assert_eq!(count(&conn, "items"), 1);
        assert_eq!(count(&conn, "outbox"), 0);
    }

    #[test]
    fn move_item_queues_a_move_and_moving_in_place_does_nothing() {
        let (_d, conn) = fresh();
        with_topics(&conn);
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        move_item(&conn, "i", Some("t"), 2).unwrap();
        assert_eq!(list_items(&conn, &View::Topic { id: "t".into() }, None).unwrap().len(), 1);
        move_item(&conn, "i", Some("t"), 3).unwrap();
        move_item(&conn, "i", None, 4).unwrap();
        assert_eq!(list_items(&conn, &View::Inbox, None).unwrap().len(), 1);
        let moves: Vec<serde_json::Value> = outbox_ops(&conn).into_iter().map(|o| o["topic_id"].clone()).collect();
        assert_eq!(moves, [serde_json::json!("t"), serde_json::Value::Null]);
        assert!(move_item(&conn, "missing", None, 5).is_err());
    }
}
