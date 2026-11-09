use std::path::Path;

use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::files;
use crate::ops;

// The Server's limit, so the Server never rejects a Capture.
const MAX_ITEM_TEXT_BYTES: usize = 1 << 20;
pub(crate) const PAGE_SIZE: i64 = 100;

#[derive(Serialize)]
pub struct FeedItem {
    pub id: String,
    pub text: Option<String>,
    pub capture_time_us: i64,
    pub topic_id: Option<String>,
    pub in_tunnel: bool,
    pub pending: bool,
    pub purge_at_us: Option<i64>,
    pub edit_base: i64,
    pub sync_error: Option<String>,
    pub conflict: Option<Conflict>,
    pub attachments: Vec<FeedAttachment>,
}

/// The version of the text that is not on the Server.
#[derive(Serialize)]
pub struct Conflict {
    pub text: Option<String>,
    pub mine: bool,
}

pub(crate) const FEEDBACK: &str = "items.sync_error, (SELECT mine FROM conflicts WHERE item_id = items.id),
    (SELECT text FROM conflicts WHERE item_id = items.id)";

pub(crate) fn feedback(r: &rusqlite::Row, first: usize) -> rusqlite::Result<(Option<String>, Option<Conflict>)> {
    let (mine, text): (Option<bool>, Option<String>) = (r.get(first + 1)?, r.get(first + 2)?);
    Ok((r.get(first)?, mine.map(|mine| Conflict { text, mine })))
}

#[derive(Serialize, Debug, PartialEq)]
pub struct Counts {
    pub inbox: i64,
    pub tunnel: i64,
    pub trash: i64,
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
    Tunnel,
    Trash,
    Topic { id: String },
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Target {
    Inbox,
    Tunnel,
    Topic { id: String },
}

#[derive(Deserialize)]
pub struct Before {
    pub capture_time_us: i64,
    pub id: String,
    pub purge_at_us: Option<i64>,
}

const GONE: &str = "That Item no longer exists";

fn checked_text(text: &str) -> Result<Option<String>, String> {
    let text = text.trim();
    if text.len() > MAX_ITEM_TEXT_BYTES {
        return Err("That's too long to save (1 MB max)".into());
    }
    if text.contains('\0') {
        return Err("That text contains a character that can't be saved".into());
    }
    Ok((!text.is_empty()).then(|| text.to_string()))
}

fn staged_attachments(dir: &Path, ids: &[String]) -> Result<Vec<ops::NewAttachment>, String> {
    let mut attachments = Vec::new();
    for id in ids {
        let id = uuid::Uuid::parse_str(id).map_err(|_| "An attachment is missing; add it again")?.to_string();
        let (filename, size_bytes) = files::staged_file(dir, &id)?;
        if size_bytes > files::MAX_ATTACHMENT_BYTES {
            return Err(format!("{filename} is over 100 MB"));
        }
        let mime_type = files::mime_type(&filename);
        attachments.push(ops::NewAttachment { id, filename, mime_type, size_bytes: size_bytes as i64 });
    }
    Ok(attachments)
}

// The pinned local copy: eviction skips it until the Server has the file.
fn pin(conn: &Connection, a: &ops::NewAttachment, now_us: i64) -> Result<(), String> {
    conn.execute(
        "INSERT INTO cached_files (attachment_id, kind, path, size_bytes, last_used_at) VALUES (?1, 'file', ?2, ?3, ?4)",
        (&a.id, format!("files/{}/{}", a.id, a.filename), a.size_bytes, now_us),
    )
    .map(|_| ())
    .map_err(crate::error_message::message)
}

pub fn capture(
    conn: &Connection,
    dir: &Path,
    text: &str,
    attachment_ids: &[String],
    target: &Target,
    draft: Option<&str>,
    now_us: i64,
) -> Result<(), String> {
    let text = checked_text(text)?;
    if text.is_none() && attachment_ids.is_empty() {
        return Err("Write something first".into());
    }
    let (topic_id, tunnel) = match target {
        Target::Inbox => (None, false),
        Target::Tunnel => (None, true),
        Target::Topic { id } => {
            crate::topics::require_open(conn, id)?;
            (Some(id.as_str()), false)
        }
    };
    let attachments = staged_attachments(dir, attachment_ids)?;
    let item_id = uuid::Uuid::new_v4().to_string();

    let tx = conn.unchecked_transaction().map_err(crate::error_message::message)?;
    tx.execute(
        "INSERT INTO items (id, topic_id, text, capture_time, in_tunnel) VALUES (?1, ?2, ?3, ?4, ?5)",
        (&item_id, topic_id, &text, now_us, tunnel),
    )
    .map_err(crate::error_message::message)?;
    for a in &attachments {
        tx.execute(
            "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES (?1, ?2, ?3, ?4, ?5, 0, 0)",
            (&a.id, &item_id, &a.filename, &a.mime_type, a.size_bytes),
        )
        .map_err(crate::error_message::message)?;
        pin(&tx, a, now_us)?;
    }
    ops::queue(&tx, ops::Op::CaptureItem { item_id, topic_id: topic_id.map(String::from), tunnel, text, attachments }, now_us)?;
    if let Some(place) = draft {
        tx.execute("DELETE FROM drafts WHERE place = ?1", [place]).map_err(crate::error_message::message)?;
    }
    tx.commit().map_err(crate::error_message::message)
}

#[derive(Serialize, Debug)]
pub struct Edited {
    pub trashed: bool,
}

#[allow(clippy::too_many_arguments)]
pub fn edit_item(
    conn: &Connection,
    dir: &Path,
    item_id: &str,
    text: &str,
    add_ids: &[String],
    remove_ids: &[String],
    base_rev: i64,
    now_us: i64,
) -> Result<Edited, String> {
    let text = checked_text(text)?;
    let (current, trashed): (Option<String>, bool) = conn
        .query_row("SELECT text, deleted_at IS NOT NULL FROM items WHERE id = ?1", [item_id], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(crate::error_message::message)?
        .ok_or(GONE)?;
    let files: Vec<String> = conn
        .prepare("SELECT id FROM attachments WHERE item_id = ?1")
        .and_then(|mut stmt| stmt.query_map([item_id], |r| r.get(0))?.collect())
        .map_err(crate::error_message::message)?;
    let adding = staged_attachments(dir, add_ids)?;
    let (removing, kept): (Vec<String>, Vec<String>) = files.into_iter().partition(|id| remove_ids.contains(id));

    let tx = conn.unchecked_transaction().map_err(crate::error_message::message)?;
    tx.execute("DELETE FROM conflicts WHERE item_id = ?1", [item_id]).map_err(crate::error_message::message)?;
    let item = || item_id.to_string();
    if text.is_none() && kept.is_empty() && adding.is_empty() {
        // Trash keeps the content, so Undo brings the whole Item back.
        if !trashed {
            ops::queue(&tx, ops::Op::TrashItem { item_id: item() }, now_us)?;
        }
        tx.commit().map_err(crate::error_message::message)?;
        return Ok(Edited { trashed: true });
    }
    // Only SetText and AddAttachment restore on the Server, and saving an Item always brings it back.
    if trashed && adding.is_empty() && text == current {
        ops::queue(&tx, ops::Op::RestoreItem { item_id: item() }, now_us)?;
    }
    // The Server trashes an Item that any single op leaves empty, so files go in first and out last.
    for a in adding {
        pin(&tx, &a, now_us)?;
        ops::queue(&tx, ops::Op::AddAttachment { item_id: item(), attachment: a }, now_us)?;
    }
    if text != current {
        ops::queue(&tx, ops::Op::SetText { item_id: item(), text, base_rev }, now_us)?;
    }
    for attachment_id in removing {
        ops::queue(&tx, ops::Op::RemoveAttachment { item_id: item(), attachment_id }, now_us)?;
    }
    tx.commit().map_err(crate::error_message::message)?;
    Ok(Edited { trashed: false })
}

pub fn discard_item(conn: &Connection, dir: &Path, item_id: &str) -> Result<(), String> {
    let refused: bool = conn
        .query_row("SELECT sync_error IS NOT NULL FROM items WHERE id = ?1", [item_id], |r| r.get(0))
        .optional()
        .map_err(crate::error_message::message)?
        .ok_or(GONE)?;
    if !refused {
        return Err("Only an Item the Server refused can be discarded".into());
    }
    let cached: Vec<(String, String)> = conn
        .prepare("SELECT c.kind, c.path FROM cached_files c JOIN attachments a ON a.id = c.attachment_id WHERE a.item_id = ?1")
        .and_then(|mut stmt| stmt.query_map([item_id], |r| Ok((r.get(0)?, r.get(1)?)))?.collect())
        .map_err(crate::error_message::message)?;
    let tx = conn.unchecked_transaction().map_err(crate::error_message::message)?;
    tx.execute("DELETE FROM cached_files WHERE attachment_id IN (SELECT id FROM attachments WHERE item_id = ?1)", [item_id])
        .map_err(crate::error_message::message)?;
    tx.execute("DELETE FROM items WHERE id = ?1", [item_id]).map_err(crate::error_message::message)?;
    tx.commit().map_err(crate::error_message::message)?;
    for (kind, path) in cached {
        let path = dir.join(path);
        let _ = std::fs::remove_file(&path);
        if kind == "file" {
            let _ = path.parent().map(std::fs::remove_dir);
        }
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Keep {
    Theirs,
    Mine,
}

pub fn resolve_conflict(conn: &Connection, dir: &Path, item_id: &str, keep: Keep, now_us: i64) -> Result<Edited, String> {
    let (text, mine): (Option<String>, bool) = conn
        .query_row("SELECT text, mine FROM conflicts WHERE item_id = ?1", [item_id], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(crate::error_message::message)?
        .ok_or("This conflict was already settled")?;
    if mine == matches!(keep, Keep::Theirs) {
        conn.execute("DELETE FROM conflicts WHERE item_id = ?1", [item_id]).map_err(crate::error_message::message)?;
        return Ok(Edited { trashed: false });
    }
    let base_rev: i64 = conn
        .query_row(&format!("SELECT {EDIT_BASE} FROM items WHERE id = ?1"), [item_id], |r| r.get(0))
        .map_err(crate::error_message::message)?;
    edit_item(conn, dir, item_id, text.as_deref().unwrap_or(""), &[], &[], base_rev, now_us)
}

pub fn set_many_trashed(conn: &Connection, item_ids: &[String], trashed: bool, now_us: i64) -> Result<(), String> {
    let tx = conn.unchecked_transaction().map_err(crate::error_message::message)?;
    let mut seen = std::collections::HashSet::new();
    for id in item_ids.iter().filter(|id| seen.insert(id.as_str())) {
        let available = tx.query_row(
            "SELECT sync_error IS NULL AND (deleted_at IS NOT NULL) != ?2 AND (?2 OR purge_at IS NULL OR purge_at > ?3) AND (?2 OR text IS NOT NULL OR EXISTS(SELECT 1 FROM attachments WHERE item_id = items.id)) FROM items WHERE id = ?1",
            rusqlite::params![id, trashed, now_us], |r| r.get::<_, bool>(0),
        ).optional().map_err(crate::error_message::message)?.unwrap_or(false);
        if !available { return Err(GONE.into()); }
        let op = if trashed { ops::Op::TrashItem { item_id: id.clone() } } else { ops::Op::RestoreItem { item_id: id.clone() } };
        ops::queue(&tx, op, now_us)?;
    }
    tx.commit().map_err(crate::error_message::message)
}

pub fn set_trashed(conn: &Connection, item_id: &str, trashed: bool, now_us: i64) -> Result<(), String> {
    let in_trash: bool = conn
        .query_row("SELECT deleted_at IS NOT NULL FROM items WHERE id = ?1", [item_id], |r| r.get(0))
        .optional()
        .map_err(crate::error_message::message)?
        .ok_or(GONE)?;
    if in_trash == trashed {
        return Ok(());
    }
    let item_id = item_id.to_string();
    let op = if trashed { ops::Op::TrashItem { item_id } } else { ops::Op::RestoreItem { item_id } };
    let tx = conn.unchecked_transaction().map_err(crate::error_message::message)?;
    ops::queue(&tx, op, now_us)?;
    tx.commit().map_err(crate::error_message::message)
}

pub fn move_item(conn: &Connection, item_id: &str, target: &Target, now_us: i64) -> Result<(), String> {
    let current: (Option<String>, bool) = conn
        .query_row("SELECT topic_id, in_tunnel FROM items WHERE id = ?1 AND deleted_at IS NULL", [item_id], |r| Ok((r.get(0)?, r.get(1)?)))
        .optional()
        .map_err(crate::error_message::message)?
        .ok_or(GONE)?;
    let (topic_id, tunnel) = match target {
        Target::Inbox => (None, false),
        Target::Tunnel => (None, true),
        Target::Topic { id } => (Some(id.as_str()), false),
    };
    if (current.0.as_deref(), current.1) == (topic_id, tunnel) {
        return Ok(());
    }
    if let Some(id) = topic_id {
        crate::topics::require_open(conn, id)?;
    }
    let tx = conn.unchecked_transaction().map_err(crate::error_message::message)?;
    ops::queue(&tx, ops::Op::MoveItem { item_id: item_id.into(), topic_id: topic_id.map(String::from), tunnel }, now_us)?;
    tx.commit().map_err(crate::error_message::message)
}

// Unsynced: an op still queued for the Item, or one of its files not uploaded yet.
pub(crate) const PENDING: &str = "(sync_error IS NULL AND (EXISTS (SELECT 1 FROM outbox WHERE json_extract(op, '$.item_id') = items.id)
    OR EXISTS (SELECT 1 FROM attachments a JOIN cached_files c ON c.attachment_id = a.id AND c.kind = 'file'
               WHERE a.item_id = items.id AND a.uploaded = 0)))";

// The revision the user is looking at: their own unpushed text if any, else the Server's.
pub(crate) const EDIT_BASE: &str = "COALESCE(
    (SELECT json_extract(op, '$.base_rev') FROM outbox
     WHERE json_extract(op, '$.item_id') = items.id AND json_extract(op, '$.type') = 'SetText'
     ORDER BY seq DESC LIMIT 1),
    items.text_rev)";

// Past purge_at the Server is about to delete it; an empty Item can't be restored. `?1` is now.
const IN_TRASH: &str = "deleted_at IS NOT NULL AND (purge_at IS NULL OR purge_at > ?1)
    AND (text IS NOT NULL OR EXISTS (SELECT 1 FROM attachments WHERE item_id = items.id))";

const PURGE_ORDER: &str = "CASE ?2 WHEN 'trash' THEN COALESCE(purge_at, 9223372036854775807) ELSE 0 END";

/// Newest first (Trash: latest purge first), at most PAGE_SIZE. `before` continues from the last Item of the previous page.
pub fn list_items(conn: &Connection, view: &View, before: Option<&Before>, now_us: i64) -> rusqlite::Result<Vec<FeedItem>> {
    let (kind, topic) = match view {
        View::All => ("all", None),
        View::Inbox => ("inbox", None),
        View::Tunnel => ("tunnel", None),
        View::Trash => ("trash", None),
        View::Topic { id } => ("topic", Some(id.as_str())),
    };
    let mut stmt = conn.prepare(&format!(
        "SELECT id, text, capture_time, topic_id, {PENDING}, purge_at, {EDIT_BASE}, {FEEDBACK}, in_tunnel
         FROM items
         WHERE CASE ?2 WHEN 'trash' THEN {IN_TRASH}
               ELSE deleted_at IS NULL
                    AND CASE ?2 WHEN 'all' THEN 1 WHEN 'inbox' THEN topic_id IS NULL AND in_tunnel = 0
                         WHEN 'tunnel' THEN in_tunnel = 1 ELSE topic_id = ?3 END END
           AND (?4 IS NULL OR ({PURGE_ORDER}, capture_time, id) < (?7, ?4, ?5))
         ORDER BY {PURGE_ORDER} DESC, capture_time DESC, id DESC
         LIMIT ?6"
    ))?;
    let purge_key = before.map(|b| if kind == "trash" { b.purge_at_us.unwrap_or(i64::MAX) } else { 0 });
    let mut items: Vec<FeedItem> = stmt
        .query_map(
            (now_us, kind, topic, before.map(|b| b.capture_time_us), before.map(|b| b.id.as_str()), PAGE_SIZE, purge_key),
            |r| {
                let (sync_error, conflict) = feedback(r, 7)?;
                Ok(FeedItem {
                    id: r.get(0)?,
                    text: r.get(1)?,
                    capture_time_us: r.get(2)?,
                    topic_id: r.get(3)?,
                    in_tunnel: r.get(10)?,
                    pending: r.get(4)?,
                    purge_at_us: r.get(5)?,
                    edit_base: r.get(6)?,
                    sync_error,
                    conflict,
                    attachments: Vec::new(),
                })
            },
        )?
        .collect::<rusqlite::Result<_>>()?;
    attach(conn, &mut items)?;
    Ok(items)
}

pub(crate) fn attach(conn: &Connection, items: &mut [FeedItem]) -> rusqlite::Result<()> {
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
    Ok(())
}

pub fn nav_counts(conn: &Connection, now_us: i64) -> rusqlite::Result<Counts> {
    conn.query_row(
        &format!(
            "SELECT (SELECT count(*) FROM items WHERE deleted_at IS NULL AND topic_id IS NULL AND in_tunnel = 0),
                    (SELECT count(*) FROM items WHERE deleted_at IS NULL AND in_tunnel = 1),
                    (SELECT count(*) FROM items WHERE {IN_TRASH})"
        ),
        [now_us],
        |r| Ok(Counts { inbox: r.get(0)?, tunnel: r.get(1)?, trash: r.get(2)? }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capture_deletes_its_draft_in_the_same_transaction() {
        let (d, conn) = fresh();
        crate::drafts::save(&conn, "inbox", "b", None).unwrap();
        capture(&conn, d.path(), "b", &[], &Target::Inbox, Some("inbox"), 1).unwrap();
        assert!(crate::drafts::list(&conn).unwrap().is_empty());
        let items = list_items(&conn, &View::Inbox, None, 0).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].text.as_deref(), Some("b"));
        assert_eq!(count(&conn, "outbox"), 1);

        crate::drafts::save(&conn, "inbox", "kept", None).unwrap();
        conn.execute_batch("CREATE TRIGGER refuse_draft_delete BEFORE DELETE ON drafts
            BEGIN SELECT RAISE(ABORT, 'refused'); END;").unwrap();
        assert!(capture(&conn, d.path(), "kept", &[], &Target::Inbox, Some("inbox"), 2).is_err());
        assert_eq!(count(&conn, "items"), 1);
        assert_eq!(count(&conn, "outbox"), 1);
        assert_eq!(crate::drafts::list(&conn).unwrap()[0].text, "kept");
    }

    #[test]
    fn failed_capture_keeps_the_draft() {
        let (d, conn) = fresh();
        conn.execute("INSERT INTO topics (id, name, archived_at) VALUES ('x', 'Archived', 1)", []).unwrap();
        crate::drafts::save(&conn, "topic:x", "draft", None).unwrap();
        assert!(capture(&conn, d.path(), "draft", &[], &Target::Topic { id: "x".into() }, Some("topic:x"), 1).is_err());
        assert_eq!(crate::drafts::list(&conn).unwrap(), vec![crate::drafts::Draft {
            place: "topic:x".into(), text: "draft".into(), home_topic_id: None,
        }]);
        assert_eq!(count(&conn, "items"), 0);
        assert_eq!(count(&conn, "outbox"), 0);
    }

    #[test]
    fn batch_trash_and_restore_are_atomic_and_queue_each_item_once() {
        let (d, conn) = fresh();
        for text in ["first", "second"] {
            capture(&conn, d.path(), text, &[], &Target::Tunnel, None, 1).unwrap();
        }
        let ids: Vec<String> = list_items(&conn, &View::Tunnel, None, 0).unwrap().into_iter().map(|i| i.id).collect();
        conn.execute("DELETE FROM outbox", []).unwrap();
        assert!(set_many_trashed(&conn, &[ids[0].clone(), "missing".into()], true, 2).is_err());
        assert_eq!(count(&conn, "outbox"), 0);
        assert_eq!(list_items(&conn, &View::Tunnel, None, 0).unwrap().len(), 2);
        set_many_trashed(&conn, &[ids[0].clone(), ids[1].clone(), ids[0].clone()], true, 2).unwrap();
        assert_eq!(count(&conn, "outbox"), 2);
        assert!(list_items(&conn, &View::Tunnel, None, 0).unwrap().is_empty());
        assert!(set_many_trashed(&conn, &[ids[0].clone(), "missing".into()], false, 3).is_err());
        assert_eq!(count(&conn, "outbox"), 2);
        set_many_trashed(&conn, &ids, false, 3).unwrap();
        assert_eq!(count(&conn, "outbox"), 4);
        assert_eq!(list_items(&conn, &View::Tunnel, None, 0).unwrap().len(), 2);
    }

    #[test]
    fn batch_rejects_unavailable_or_wrong_state_items_without_partial_changes() {
        let (d, conn) = fresh();
        capture(&conn, d.path(), "first", &[], &Target::Inbox, None, 1).unwrap();
        capture(&conn, d.path(), "second", &[], &Target::Inbox, None, 2).unwrap();
        let ids: Vec<String> = list_items(&conn, &View::Inbox, None, 0).unwrap().into_iter().map(|i| i.id).collect();
        conn.execute("UPDATE items SET sync_error = 'invalid' WHERE id = ?1", [&ids[1]]).unwrap();
        conn.execute("DELETE FROM outbox", []).unwrap();
        assert!(set_many_trashed(&conn, &ids, true, 3).is_err());
        assert_eq!(count(&conn, "outbox"), 0);
        assert_eq!(list_items(&conn, &View::Inbox, None, 0).unwrap().len(), 2);
        conn.execute("UPDATE items SET sync_error = NULL, deleted_at = 2, purge_at = 3 WHERE id = ?1", [&ids[1]]).unwrap();
        assert!(set_many_trashed(&conn, &ids, true, 4).is_err());
        assert!(set_many_trashed(&conn, &[ids[1].clone()], false, 4).is_err());
        conn.execute("UPDATE items SET text = NULL, purge_at = NULL WHERE id = ?1", [&ids[1]]).unwrap();
        assert!(set_many_trashed(&conn, &[ids[1].clone()], false, 4).is_err());
    }

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
        capture(&conn, d.path(), "  hello\n", &[], &Target::Inbox, None, 1_760_000_000_123_456).unwrap();

        let items = list_items(&conn, &View::All, None, 0).unwrap();
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
            assert!(capture(&conn, d.path(), text, &[], &Target::Inbox, None, 1).is_err(), "accepted {:.20?}", text);
        }
        assert_eq!(count(&conn, "items"), 0);
        assert_eq!(count(&conn, "outbox"), 0);
        // The limit itself is allowed, so the guard above is the byte limit and not something stricter.
        capture(&conn, d.path(), &"x".repeat(MAX_ITEM_TEXT_BYTES), &[], &Target::Inbox, None, 1).unwrap();
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
            list_items(&conn, &view, None, 0).unwrap().into_iter().map(|i| i.id).collect()
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
        let first = list_items(&conn, &View::All, None, 0).unwrap();
        assert_eq!(first.len(), PAGE_SIZE as usize);
        let last = first.last().unwrap();
        let before = Before { capture_time_us: last.capture_time_us, id: last.id.clone(), purge_at_us: None };
        let second = list_items(&conn, &View::All, Some(&before), 0).unwrap();

        let mut all: Vec<String> = first.into_iter().chain(second).map(|i| i.id).collect();
        assert_eq!(all.len(), PAGE_SIZE as usize + 1);
        all.sort();
        all.dedup();
        assert_eq!(all.len(), PAGE_SIZE as usize + 1, "an Item was repeated");
    }

    #[test]
    fn trash_pages_latest_purge_first_whatever_the_capture_order() {
        let (_d, conn) = fresh();
        for i in 0..=PAGE_SIZE {
            conn.execute(
                "INSERT INTO items (id, text, capture_time, deleted_at, purge_at) VALUES (?1, 'x', ?2, 1, ?3)",
                (format!("{i:03}"), i, if i == 7 { None } else { Some(5000 + (i * 37) % 11) }),
            )
            .unwrap();
        }
        let first = list_items(&conn, &View::Trash, None, 0).unwrap();
        assert_eq!(first.len(), PAGE_SIZE as usize);
        let last = first.last().unwrap();
        let before = Before { capture_time_us: last.capture_time_us, id: last.id.clone(), purge_at_us: last.purge_at_us };
        let second = list_items(&conn, &View::Trash, Some(&before), 0).unwrap();

        let all: Vec<FeedItem> = first.into_iter().chain(second).collect();
        assert_eq!(all.len(), PAGE_SIZE as usize + 1);
        let keys: Vec<_> = all.iter().map(|i| (i.purge_at_us.unwrap_or(i64::MAX), i.capture_time_us)).collect();
        assert!(keys.windows(2).all(|w| w[0] > w[1]), "not latest purge first: {keys:?}");
    }

    #[test]
    fn an_item_stops_pending_when_its_op_leaves_the_outbox() {
        let (d, conn) = fresh();
        capture(&conn, d.path(), "hi", &[], &Target::Inbox, None, 1).unwrap();
        conn.execute("DELETE FROM outbox", []).unwrap();
        assert!(!list_items(&conn, &View::All, None, 0).unwrap()[0].pending);
    }

    fn png(d: &tempfile::TempDir) -> String {
        crate::files::stage_bytes(d.path(), "scan.png", b"png").unwrap().id
    }

    #[test]
    fn an_attachment_is_captured_with_its_item_in_one_transaction() {
        let (d, conn) = fresh();
        let id = png(&d);
        capture(&conn, d.path(), "  ", std::slice::from_ref(&id), &Target::Inbox, None, 1_760_000_000_000_000).unwrap();

        let item = &list_items(&conn, &View::All, None, 0).unwrap()[0];
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
            assert!(capture(&conn, d.path(), "hi", &[bad.to_string()], &Target::Inbox, None, 1).is_err(), "accepted {bad}");
        }
        assert_eq!(count(&conn, "items"), 0);
        assert_eq!(count(&conn, "outbox"), 0);
        assert!(capture(&conn, d.path(), " ", &[], &Target::Inbox, None, 1).is_err(), "blank with no attachments");
    }

    #[test]
    fn an_item_stays_pending_until_its_files_are_uploaded() {
        let (d, conn) = fresh();
        let id = png(&d);
        capture(&conn, d.path(), "photo", std::slice::from_ref(&id), &Target::Inbox, None, 1).unwrap();
        conn.execute("DELETE FROM outbox", []).unwrap();
        assert!(list_items(&conn, &View::All, None, 0).unwrap()[0].pending, "the file isn't on the Server yet");
        conn.execute("UPDATE attachments SET uploaded = 1", []).unwrap();
        assert!(!list_items(&conn, &View::All, None, 0).unwrap()[0].pending);
    }

    fn types(conn: &Connection) -> Vec<String> {
        outbox_ops(conn).into_iter().map(|o| o["type"].as_str().unwrap().to_string()).collect()
    }

    fn with_file(conn: &Connection, item: &str, text: Option<&str>, file: &str) {
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES (?1, ?2, 1)", (item, text)).unwrap();
        conn.execute(
            "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES (?1, ?2, 'f.pdf', 'application/pdf', 1, 1, 0)",
            (file, item),
        )
        .unwrap();
    }

    #[test]
    fn an_edit_queues_only_what_changed_adding_before_removing() {
        let (d, conn) = fresh();
        with_file(&conn, "i", Some("old"), "a");
        let new = png(&d);
        let edited = edit_item(&conn, d.path(), "i", " new ", std::slice::from_ref(&new), &["a".into()], 0, 5).unwrap();
        assert!(!edited.trashed);
        assert_eq!(types(&conn), ["AddAttachment", "SetText", "RemoveAttachment"]);
        assert_eq!(outbox_ops(&conn)[1]["text"], "new");
        let item = &list_items(&conn, &View::All, None, 0).unwrap()[0];
        assert_eq!(item.text.as_deref(), Some("new"));
        assert_eq!(item.attachments.iter().map(|a| a.id.as_str()).collect::<Vec<_>>(), [new.as_str()]);
        assert!(item.pending);
        let pinned: i64 = conn
            .query_row("SELECT count(*) FROM cached_files WHERE attachment_id = ?1 AND kind = 'file'", [&new], |r| r.get(0))
            .unwrap();
        assert_eq!(pinned, 1, "the new file isn't pinned until uploaded");

        conn.execute("DELETE FROM outbox", []).unwrap();
        edit_item(&conn, d.path(), "i", "new", &[], &[], 0, 6).unwrap();
        assert_eq!(count(&conn, "outbox"), 0, "an unchanged save queued something");
    }

    #[test]
    fn edit_base_follows_a_pending_set_text() {
        let (d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time, text_rev) VALUES ('i', 'x', 1, 3)", []).unwrap();
        let base = |conn: &Connection| list_items(conn, &View::All, None, 0).unwrap()[0].edit_base;
        assert_eq!(base(&conn), 3);
        edit_item(&conn, d.path(), "i", "y", &[], &[], 3, 2).unwrap();
        conn.execute("UPDATE items SET text_rev = 4", []).unwrap();
        assert_eq!(base(&conn), 3);
        edit_item(&conn, d.path(), "i", "z", &[], &[], 4, 3).unwrap();
        assert_eq!(base(&conn), 4, "the newest pending edit decides");
        conn.execute("UPDATE items SET text_rev = 5", []).unwrap();
        conn.execute("DELETE FROM outbox", []).unwrap();
        assert_eq!(base(&conn), 5);
    }

    fn set_conflict(conn: &Connection, text: Option<&str>, mine: bool) {
        conn.execute("INSERT INTO conflicts (item_id, text, mine) VALUES ('i', ?1, ?2)", (text, mine)).unwrap();
    }

    #[test]
    fn discard_refuses_a_synced_item() {
        let (d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        assert!(discard_item(&conn, d.path(), "i").is_err());
        assert_eq!(count(&conn, "items"), 1);
    }

    #[test]
    fn discard_removes_a_refused_capture_and_its_files() {
        let (d, conn) = fresh();
        let id = png(&d);
        capture(&conn, d.path(), "hi", std::slice::from_ref(&id), &Target::Inbox, None, 1).unwrap();
        conn.execute("UPDATE items SET sync_error = 'invalid'", []).unwrap();
        let file = d.path().join("files").join(&id).join("scan.png");
        assert!(file.exists());

        discard_item(&conn, d.path(), &list_items(&conn, &View::All, None, 0).unwrap()[0].id).unwrap();
        for table in ["items", "attachments", "cached_files"] {
            assert_eq!(count(&conn, table), 0, "{table}");
        }
        assert!(!file.exists());
    }

    #[test]
    fn keeping_the_version_already_on_the_server_only_clears_the_row() {
        for (mine, keep) in [(true, Keep::Theirs), (false, Keep::Mine)] {
            let (d, conn) = fresh();
            conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
            set_conflict(&conn, Some("other"), mine);
            resolve_conflict(&conn, d.path(), "i", keep, 2).unwrap();
            assert_eq!(count(&conn, "conflicts"), 0);
            assert_eq!(count(&conn, "outbox"), 0);
        }
    }

    #[test]
    fn keeping_the_other_version_sends_it_from_the_current_revision() {
        let (d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time, text_rev) VALUES ('i', 'x', 1, 4)", []).unwrap();
        set_conflict(&conn, Some("mine"), true);
        resolve_conflict(&conn, d.path(), "i", Keep::Mine, 2).unwrap();
        let ops = outbox_ops(&conn);
        assert_eq!(ops.len(), 1);
        assert_eq!((ops[0]["type"].as_str(), ops[0]["text"].as_str(), ops[0]["base_rev"].as_i64()), (Some("SetText"), Some("mine"), Some(4)));
        assert_eq!(count(&conn, "conflicts"), 0);
    }

    #[test]
    fn keeping_the_other_devices_version_sends_its_stored_text() {
        let (d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time, text_rev) VALUES ('i', 'x', 1, 4)", []).unwrap();
        set_conflict(&conn, Some("theirs"), false);
        resolve_conflict(&conn, d.path(), "i", Keep::Theirs, 2).unwrap();
        let ops = outbox_ops(&conn);
        assert_eq!(ops.len(), 1);
        assert_eq!((ops[0]["type"].as_str(), ops[0]["text"].as_str(), ops[0]["base_rev"].as_i64()), (Some("SetText"), Some("theirs"), Some(4)));
        assert_eq!(count(&conn, "conflicts"), 0);
    }

    #[test]
    fn keeping_a_null_text_with_no_files_trashes() {
        let (d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        set_conflict(&conn, None, true);
        assert!(resolve_conflict(&conn, d.path(), "i", Keep::Mine, 2).unwrap().trashed);
        assert_eq!(types(&conn), ["TrashItem"]);
        assert_eq!(count(&conn, "conflicts"), 0);
    }

    #[test]
    fn list_items_carries_sync_error_and_conflict() {
        let (_d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time, sync_error) VALUES ('i', 'x', 1, 'invalid')", []).unwrap();
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('j', 'y', 0)", []).unwrap();
        conn.execute("INSERT INTO conflicts (item_id, text, mine) VALUES ('j', NULL, 0)", []).unwrap();
        let items = list_items(&conn, &View::All, None, 0).unwrap();
        assert_eq!(items[0].sync_error.as_deref(), Some("invalid"));
        assert!(items[0].conflict.is_none());
        assert_eq!(items[1].sync_error, None);
        let c = items[1].conflict.as_ref().unwrap();
        assert_eq!((c.text.as_deref(), c.mine), (None, false));
    }

    #[test]
    fn saving_clears_the_items_conflict() {
        let (d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        conn.execute("INSERT INTO conflicts (item_id, text, mine) VALUES ('i', 'z', 1)", []).unwrap();
        edit_item(&conn, d.path(), "i", "y", &[], &[], 0, 2).unwrap();
        assert_eq!(count(&conn, "conflicts"), 0);
    }

    #[test]
    fn emptying_an_item_trashes_it_and_keeps_its_content() {
        let (d, conn) = fresh();
        with_file(&conn, "i", Some("x"), "a");
        assert!(edit_item(&conn, d.path(), "i", "  ", &[], &["a".into()], 0, 5).unwrap().trashed);
        assert_eq!(types(&conn), ["TrashItem"]);
        let (text, deleted): (Option<String>, Option<i64>) =
            conn.query_row("SELECT text, deleted_at FROM items WHERE id = 'i'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert_eq!((text.as_deref(), deleted), (Some("x"), Some(5)));
        assert_eq!(count(&conn, "attachments"), 1);
    }

    #[test]
    fn a_bad_edit_writes_nothing() {
        let (d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        let too_long = "x".repeat(MAX_ITEM_TEXT_BYTES + 1);
        for text in ["a\0b", too_long.as_str()] {
            assert!(edit_item(&conn, d.path(), "i", text, &[], &[], 0, 2).is_err(), "accepted {:.20?}", text);
        }
        assert!(edit_item(&conn, d.path(), "i", "y", &["../files".into()], &[], 0, 2).is_err());
        assert_eq!(edit_item(&conn, d.path(), "nope", "y", &[], &[], 0, 2).unwrap_err(), GONE);
        assert_eq!(count(&conn, "outbox"), 0);
    }

    #[test]
    fn an_edit_leaves_another_items_files_alone() {
        let (d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        with_file(&conn, "j", Some("y"), "b");
        edit_item(&conn, d.path(), "i", "x2", &[], &["b".into()], 0, 2).unwrap();
        assert_eq!(types(&conn), ["SetText"]);
        assert_eq!(count(&conn, "attachments"), 1);
    }

    #[test]
    fn editing_an_item_in_trash_restores_it() {
        let (d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time, deleted_at, purge_at) VALUES ('i', 'x', 1, 3, 99)", []).unwrap();
        edit_item(&conn, d.path(), "i", "back", &[], &[], 0, 4).unwrap();
        assert_eq!(list_items(&conn, &View::All, None, 0).unwrap()[0].text.as_deref(), Some("back"));
    }

    #[test]
    fn saving_an_item_in_trash_without_an_edit_that_restores_queues_a_restore() {
        let (d, conn) = fresh();
        with_file(&conn, "i", Some("x"), "a");
        conn.execute_batch(
            "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES ('b', 'i', 'g.pdf', 'application/pdf', 1, 1, 0);
             UPDATE items SET deleted_at = 3;",
        )
        .unwrap();
        edit_item(&conn, d.path(), "i", "x", &[], &[], 0, 4).unwrap();
        assert_eq!(types(&conn), ["RestoreItem"]);
        conn.execute_batch("DELETE FROM outbox; UPDATE items SET deleted_at = 5").unwrap();
        edit_item(&conn, d.path(), "i", "x", &[], &["a".into()], 0, 6).unwrap();
        assert_eq!(types(&conn), ["RestoreItem", "RemoveAttachment"]);
        assert_eq!(list_items(&conn, &View::All, None, 0).unwrap().len(), 1);
    }

    #[test]
    fn trash_and_restore_queue_once_and_refuse_a_missing_item() {
        let (_d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        set_trashed(&conn, "i", true, 5).unwrap();
        set_trashed(&conn, "i", true, 6).unwrap();
        assert!(list_items(&conn, &View::All, None, 0).unwrap().is_empty());
        set_trashed(&conn, "i", false, 7).unwrap();
        set_trashed(&conn, "i", false, 8).unwrap();
        assert_eq!(types(&conn), ["TrashItem", "RestoreItem"]);
        assert_eq!(set_trashed(&conn, "nope", true, 9).unwrap_err(), GONE);
        assert_eq!(set_trashed(&conn, "nope", false, 9).unwrap_err(), GONE);
    }

    #[test]
    fn trash_lists_items_until_their_purge_time_and_never_empty_ones() {
        let (_d, conn) = fresh();
        conn.execute_batch(
            "INSERT INTO items (id, topic_id, text, capture_time) VALUES ('live', NULL, 'a', 1), ('filed', 'T', 'b', 1);
             INSERT INTO items (id, text, capture_time, deleted_at, purge_at) VALUES
                 ('counting', 'c', 2, 1, 1001), ('unsynced', 'd', 3, 1, NULL), ('due', 'e', 4, 1, 1000),
                 ('empty', NULL, 5, 1, 2000), ('files', NULL, 6, 1, 2000);
             INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES ('f', 'files', 'f.pdf', 'application/pdf', 1, 1, 0);",
        )
        .unwrap();
        let trash = list_items(&conn, &View::Trash, None, 1000).unwrap();
        assert_eq!(trash.iter().map(|i| i.id.as_str()).collect::<Vec<_>>(), ["unsynced", "files", "counting"]);
        assert_eq!(trash.iter().map(|i| i.purge_at_us).collect::<Vec<_>>(), [None, Some(2000), Some(1001)]);
        assert_eq!(nav_counts(&conn, 1000).unwrap(), Counts { inbox: 1, tunnel: 0, trash: 3 });
    }

    #[test]
    fn the_pending_check_finds_an_items_ops_by_index() {
        let (_d, conn) = fresh();
        let mut stmt = conn
            .prepare(
                "EXPLAIN QUERY PLAN SELECT 1 FROM items
                 WHERE EXISTS (SELECT 1 FROM outbox WHERE json_extract(op, '$.item_id') = items.id)",
            )
            .unwrap();
        let plan: Vec<String> = stmt.query_map([], |r| r.get(3)).unwrap().map(Result::unwrap).collect();
        assert!(plan.iter().any(|step| step.contains("outbox_item")), "{plan:?}");
    }

    #[test]
    fn the_feed_marks_files_that_can_run_code() {
        let (d, conn) = fresh();
        let ids = ["setup.command", "report.pdf"].map(|n| crate::files::stage_bytes(d.path(), n, b"x").unwrap().id);
        capture(&conn, d.path(), "", &ids, &Target::Inbox, None, 1).unwrap();
        let item = &list_items(&conn, &View::All, None, 0).unwrap()[0];
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
        capture(&conn, d.path(), "squat 100", &[], &Target::Topic { id: "t".into() }, None, 1).unwrap();
        let ids: Vec<String> = list_items(&conn, &View::Topic { id: "t".into() }, None, 0).unwrap().into_iter().map(|i| i.id).collect();
        assert_eq!(ids.len(), 1);
        assert_eq!(outbox_ops(&conn)[0]["topic_id"], "t");
    }

    #[test]
    fn capture_and_move_refuse_topics_that_cant_take_items() {
        let (d, conn) = fresh();
        with_topics(&conn);
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        for id in ["a", "d", "nope"] {
            assert!(capture(&conn, d.path(), "hi", &[], &Target::Topic { id: id.into() }, None, 1).is_err(), "captured into {id}");
            assert!(move_item(&conn, "i", &Target::Topic { id: id.into() }, 1).is_err(), "moved into {id}");
        }
        assert_eq!(count(&conn, "items"), 1);
        assert_eq!(count(&conn, "outbox"), 0);
    }

    #[test]
    fn move_item_queues_a_move_and_moving_in_place_does_nothing() {
        let (_d, conn) = fresh();
        with_topics(&conn);
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        move_item(&conn, "i", &Target::Topic { id: "t".into() }, 2).unwrap();
        assert_eq!(list_items(&conn, &View::Topic { id: "t".into() }, None, 0).unwrap().len(), 1);
        move_item(&conn, "i", &Target::Topic { id: "t".into() }, 3).unwrap();
        move_item(&conn, "i", &Target::Inbox, 4).unwrap();
        assert_eq!(list_items(&conn, &View::Inbox, None, 0).unwrap().len(), 1);
        let moves: Vec<serde_json::Value> = outbox_ops(&conn).into_iter().map(|o| o["topic_id"].clone()).collect();
        assert_eq!(moves, [serde_json::json!("t"), serde_json::Value::Null]);
        assert!(move_item(&conn, "missing", &Target::Inbox, 5).is_err());
    }

    #[test]
    fn tunnel_and_inbox_are_disjoint_and_count_only_live_items() {
        let (_d, conn) = fresh();
        let tunnel: View = serde_json::from_value(serde_json::json!({"kind":"tunnel"})).unwrap();
        conn.execute_batch("INSERT INTO items (id, text, capture_time, topic_id, in_tunnel, deleted_at) VALUES
            ('inbox', 'note', 1, NULL, 0, NULL), ('tunnel', 'note', 2, NULL, 1, NULL),
            ('topic', 'note', 3, 't', 0, NULL), ('trash', 'note', 4, NULL, 1, 5);").unwrap();
        let ids = |view: &View| list_items(&conn, view, None, 0).unwrap().into_iter().map(|i| i.id).collect::<Vec<_>>();
        assert_eq!(ids(&tunnel), ["tunnel"]);
        assert_eq!(serde_json::to_value(&list_items(&conn, &tunnel, None, 0).unwrap()[0]).unwrap()["in_tunnel"], true);
        assert_eq!(ids(&View::Inbox), ["inbox"]);
        assert_eq!(ids(&View::All), ["topic", "tunnel", "inbox"]);
        assert_eq!(serde_json::to_value(nav_counts(&conn, 0).unwrap()).unwrap(), serde_json::json!({"inbox":1,"tunnel":1,"trash":1}));
    }

    #[test]
    fn capture_and_move_through_tunnel_topic_and_inbox_queue_the_whole_place() {
        let (d, conn) = fresh();
        with_topics(&conn);
        let target: Target = serde_json::from_value(serde_json::json!({"kind":"tunnel"})).unwrap();
        capture(&conn, d.path(), "transfer", &[], &target, None, 1).unwrap();
        let id = list_items(&conn, &View::Tunnel, None, 0).unwrap()[0].id.clone();
        assert_eq!(outbox_ops(&conn)[0]["tunnel"], true);
        assert_eq!(outbox_ops(&conn)[0]["topic_id"], serde_json::Value::Null);
        move_item(&conn, &id, &Target::Tunnel, 2).unwrap();
        assert_eq!(count(&conn, "outbox"), 1, "moving within the Tunnel is a no-op");
        for (json, topic, tunnel) in [
            (serde_json::json!({"kind":"topic", "id":"t"}), Some("t"), false),
            (serde_json::json!({"kind":"tunnel"}), None, true),
            (serde_json::json!({"kind":"inbox"}), None, false),
            (serde_json::json!({"kind":"tunnel"}), None, true),
        ] {
            let target: Target = serde_json::from_value(json).unwrap();
            move_item(&conn, &id, &target, 3).unwrap();
            let actual: (Option<String>, bool) = conn.query_row("SELECT topic_id, in_tunnel FROM items WHERE id = ?1", [&id], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
            assert_eq!(actual, (topic.map(String::from), tunnel));
            let ops = outbox_ops(&conn);
            let op = ops.last().unwrap();
            assert_eq!(op["type"], "MoveItem");
            assert_eq!(op["tunnel"], tunnel);
            assert_eq!(op["topic_id"], serde_json::json!(topic));
        }
        set_trashed(&conn, &id, true, 4).unwrap();
        set_trashed(&conn, &id, false, 5).unwrap();
        assert_eq!(list_items(&conn, &View::Tunnel, None, 0).unwrap()[0].id, id);
    }
}
