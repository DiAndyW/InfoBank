use rusqlite::Connection;
use serde::{Deserialize, Serialize};

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

pub fn capture(conn: &Connection, text: &str, now_us: i64) -> Result<(), String> {
    let text = text.trim();
    if text.is_empty() {
        return Err("Write something first".into());
    }
    if text.len() > MAX_ITEM_TEXT_BYTES {
        return Err("That's too long to save (1 MB max)".into());
    }
    if text.contains('\0') {
        return Err("That text contains a character that can't be saved".into());
    }
    let at = chrono::DateTime::from_timestamp_micros(now_us)
        .ok_or("The system clock is out of range")?
        .to_rfc3339_opts(chrono::SecondsFormat::Micros, true);
    let item_id = uuid::Uuid::new_v4().to_string();
    let op = serde_json::json!({
        "id": uuid::Uuid::new_v4().to_string(),
        "type": "CaptureItem",
        "at": at,
        "item_id": item_id,
        "topic_id": null,
        "text": text,
        "attachments": [],
    });

    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    tx.execute("INSERT INTO items (id, text, capture_time) VALUES (?1, ?2, ?3)", (&item_id, text, now_us))
        .map_err(|e| e.to_string())?;
    tx.execute("INSERT INTO outbox (op) VALUES (?1)", [op.to_string()]).map_err(|e| e.to_string())?;
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
         FROM items
         WHERE deleted_at IS NULL
           AND CASE ?1 WHEN 'all' THEN 1 WHEN 'inbox' THEN topic_id IS NULL ELSE topic_id = ?2 END
           AND (?3 IS NULL OR (capture_time, id) < (?3, ?4))
         ORDER BY capture_time DESC, id DESC
         LIMIT ?5",
    )?;
    stmt.query_map(
        (kind, topic, before.map(|b| b.capture_time_us), before.map(|b| b.id.as_str()), PAGE_SIZE),
        |r| {
            Ok(FeedItem {
                id: r.get(0)?,
                text: r.get(1)?,
                capture_time_us: r.get(2)?,
                topic_id: r.get(3)?,
                pending: r.get(4)?,
            })
        },
    )?
    .collect()
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
        let (_d, conn) = fresh();
        capture(&conn, "  hello\n", 1_760_000_000_123_456).unwrap();

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
        let (_d, conn) = fresh();
        let too_long = "x".repeat(MAX_ITEM_TEXT_BYTES + 1);
        for text in ["", "  \n ", "a\0b", too_long.as_str()] {
            assert!(capture(&conn, text, 1).is_err(), "accepted {:.20?}", text);
        }
        assert_eq!(count(&conn, "items"), 0);
        assert_eq!(count(&conn, "outbox"), 0);
        // The limit itself is allowed, so the guard above is the byte limit and not something stricter.
        capture(&conn, &"x".repeat(MAX_ITEM_TEXT_BYTES), 1).unwrap();
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
        let (_d, conn) = fresh();
        capture(&conn, "hi", 1).unwrap();
        conn.execute("DELETE FROM outbox", []).unwrap();
        assert!(!list_items(&conn, &View::All, None).unwrap()[0].pending);
    }
}
