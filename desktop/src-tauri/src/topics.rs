use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::ops::{self, Op};

// The Server's limit, so it never rejects a name.
const MAX_TOPIC_NAME_BYTES: usize = 200;

#[derive(Serialize, Debug, PartialEq)]
pub struct Topic {
    pub id: String,
    pub name: String,
    pub item_count: i64,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
pub enum Keep {
    All,
    None,
    Only { ids: Vec<String> },
}

pub fn list(conn: &Connection) -> rusqlite::Result<Vec<Topic>> {
    let mut stmt = conn.prepare(
        "SELECT t.id, t.name,
                (SELECT count(*) FROM items i WHERE i.topic_id = t.id AND i.deleted_at IS NULL)
         FROM topics t WHERE t.deleted_at IS NULL
         ORDER BY t.activity_at DESC, lower(t.name), t.id",
    )?;
    stmt.query_map([], |r| Ok(Topic { id: r.get(0)?, name: r.get(1)?, item_count: r.get(2)? }))?
        .collect()
}

pub fn require_open(conn: &Connection, id: &str) -> Result<(), String> {
    conn.query_row("SELECT 1 FROM topics WHERE id = ?1 AND deleted_at IS NULL", [id], |_| Ok(()))
        .optional()
        .map_err(crate::error_message::message)?
        .ok_or_else(|| "That Topic no longer exists".to_string())
}

// The apps show these as built-in places and actions; the Server refuses them too.
const BUILT_IN_NAMES: [&str; 6] = ["inbox", "tunnel", "trash", "all items", "anywhere", "new topic"];

// Unicode's format characters (category Cf): invisible, so a name made only of them looks blank.
fn is_format(c: char) -> bool {
    matches!(c as u32, 0xAD | 0x600..=0x605 | 0x61C | 0x6DD | 0x70F | 0x890..=0x891 | 0x8E2 | 0x180E | 0x200B..=0x200F
        | 0x202A..=0x202E | 0x2060..=0x2064 | 0x2066..=0x206F | 0xFEFF | 0xFFF9..=0xFFFB | 0x110BD | 0x110CD
        | 0x13430..=0x1343F | 0x1BCA0..=0x1BCA3 | 0x1D173..=0x1D17A | 0xE0001 | 0xE0020..=0xE007F)
}

fn valid_name(name: &str) -> Result<&str, String> {
    let name = name.trim();
    if name.chars().any(char::is_control) {
        return Err("A Topic name can't contain line breaks, tabs or other control characters".into());
    }
    if name.chars().all(|c| c.is_whitespace() || is_format(c)) {
        return Err("Give the Topic a name".into());
    }
    if name.len() > MAX_TOPIC_NAME_BYTES {
        return Err("That name is too long (200 bytes max)".into());
    }
    let base = name.strip_suffix('…').unwrap_or(name);
    let base = base.strip_suffix("...").unwrap_or(base).trim();
    if BUILT_IN_NAMES.contains(&base.to_lowercase().as_str()) {
        return Err(format!("“{base}” is a built-in name. Pick another."));
    }
    Ok(name)
}

fn checked_name(conn: &Connection, name: &str, own_id: &str) -> Result<String, String> {
    let name = valid_name(name)?;
    let mut stmt = conn.prepare("SELECT name FROM topics WHERE deleted_at IS NULL AND id <> ?1").map_err(crate::error_message::message)?;
    let taken = stmt
        .query_map([own_id], |r| r.get::<_, String>(0))
        .map_err(crate::error_message::message)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(crate::error_message::message)?;
    // SQLite's lower() only folds ASCII.
    if let Some(other) = taken.iter().find(|t| t.to_lowercase() == name.to_lowercase()) {
        return Err(format!("A Topic named \"{other}\" already exists"));
    }
    Ok(name.to_string())
}

fn queue_one(conn: &Connection, op: Op, now_us: i64) -> Result<(), String> {
    let tx = conn.unchecked_transaction().map_err(crate::error_message::message)?;
    ops::queue(&tx, op, now_us)?;
    tx.commit().map_err(crate::error_message::message)
}

pub fn create(conn: &Connection, name: &str, now_us: i64) -> Result<Topic, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let name = checked_name(conn, name, &id)?;
    queue_one(conn, Op::CreateTopic { topic_id: id.clone(), name: name.clone() }, now_us)?;
    Ok(Topic { id, name, item_count: 0 })
}

pub fn picker_topic(conn: &Connection, name: &str, now_us: i64) -> Result<Topic, String> {
    let lowered = valid_name(name)?.to_lowercase();
    if let Some(topic) = list(conn).map_err(crate::error_message::message)?.into_iter().find(|t| t.name.to_lowercase() == lowered) {
        return Ok(topic);
    }
    create(conn, name, now_us)
}

pub fn rename(conn: &Connection, id: &str, name: &str, now_us: i64) -> Result<(), String> {
    require_open(conn, id)?;
    let name = checked_name(conn, name, id)?;
    let current: String =
        conn.query_row("SELECT name FROM topics WHERE id = ?1", [id], |r| r.get(0)).map_err(crate::error_message::message)?;
    // A fresh stamp on an unchanged name would win over a newer rename from another Device.
    if name == current {
        return Ok(());
    }
    queue_one(conn, Op::RenameTopic { topic_id: id.into(), name }, now_us)
}

pub fn delete(conn: &Connection, id: &str, keep: &Keep, now_us: i64) -> Result<(), String> {
    require_open(conn, id)?;
    let mut stmt =
        conn.prepare("SELECT id FROM items WHERE topic_id = ?1 AND deleted_at IS NULL").map_err(crate::error_message::message)?;
    let ids = stmt
        .query_map([id], |r| r.get::<_, String>(0))
        .map_err(crate::error_message::message)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(crate::error_message::message)?;
    let trash = match keep {
        Keep::All => Vec::new(),
        Keep::None => ids,
        Keep::Only { ids: kept } => ids.into_iter().filter(|i| !kept.contains(i)).collect(),
    };
    queue_one(conn, Op::DeleteTopic { topic_id: id.into(), trash }, now_us)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
        conn.execute_batch(
            "INSERT INTO topics (id, name) VALUES ('t', 'Gym'), ('b', 'books'), ('e', 'École');
             INSERT INTO topics (id, name) VALUES ('a', 'Old');
             INSERT INTO topics (id, name, deleted_at) VALUES ('d', 'Gone', 1);",
        )
        .unwrap();
        (dir, conn)
    }

    fn outbox(conn: &Connection) -> Vec<serde_json::Value> {
        let mut stmt = conn.prepare("SELECT op FROM outbox ORDER BY seq").unwrap();
        stmt.query_map([], |r| r.get::<_, String>(0))
            .unwrap()
            .map(|op| serde_json::from_str(&op.unwrap()).unwrap())
            .collect()
    }

    #[test]
    fn list_breaks_activity_ties_by_name_then_id() {
        let (_d, conn) = fresh();
        conn.execute_batch("DELETE FROM topics;
            INSERT INTO topics (id, name) VALUES ('z', 'Alpha'), ('b', 'beta'), ('a', 'BETA');
            INSERT INTO items (id, topic_id, text, capture_time) VALUES ('1', 'z', 'x', 10), ('2', 'b', 'x', 30), ('3', 'a', 'x', 20);").unwrap();
        assert_eq!(list(&conn).unwrap().iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["z", "a", "b"]);
    }

    #[test]
    fn list_ranks_stored_activity_including_empty_and_trashed_topics() {
        let (_d, conn) = fresh();
        conn.execute_batch("DELETE FROM topics;
            INSERT INTO topics (id, name, activity_at) VALUES ('empty', 'z new empty', 40), ('old', 'old', 10), ('trash', 'a trashed-only', 30);
            INSERT INTO items (id, topic_id, text, capture_time, deleted_at) VALUES
            ('1', 'old', 'x', 10, NULL), ('2', 'trash', 'x', 30, 1);").unwrap();
        let topics = list(&conn).unwrap();
        assert_eq!(topics.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), ["empty", "trash", "old"]);
        assert_eq!(topics.iter().map(|t| t.item_count).collect::<Vec<_>>(), [0, 0, 1]);
    }

    #[test]
    fn activity_changes_only_on_create_capture_and_move_into() {
        let (d, conn) = fresh();
        conn.execute_batch("DELETE FROM topics").unwrap();
        let old = create(&conn, "Old", 10).unwrap();
        let new = picker_topic(&conn, "New", 20).unwrap();
        let activity = |id: &str| -> i64 {
            conn.query_row("SELECT activity_at FROM topics WHERE id = ?1", [id], |r| r.get(0)).unwrap()
        };
        assert_eq!((activity(&old.id), activity(&new.id)), (10, 20));
        assert_eq!(list(&conn).unwrap()[0].id, new.id);
        crate::feed::capture(&conn, d.path(), "hello", &[], &crate::feed::Target::Topic { id: old.id.clone() }, None, 30).unwrap();
        assert_eq!(activity(&old.id), 30);
        assert_eq!(list(&conn).unwrap()[0].id, old.id);
        crate::feed::capture(&conn, d.path(), "late", &[], &crate::feed::Target::Topic { id: old.id.clone() }, None, 25).unwrap();
        assert_eq!(activity(&old.id), 30);
        let item: String = conn.query_row("SELECT id FROM items WHERE text = 'hello'", [], |r| r.get(0)).unwrap();
        for op in [
            Op::TrashItem { item_id: item.clone() },
            Op::RestoreItem { item_id: item.clone() },
            Op::SetText { item_id: item.clone(), text: Some("edited".into()), base_rev: 0 },
            Op::AddAttachment { item_id: item.clone(), attachment: crate::ops::NewAttachment { id: "a".into(), filename: "a.txt".into(), mime_type: "text/plain".into(), size_bytes: 1 } },
            Op::RemoveAttachment { item_id: item.clone(), attachment_id: "a".into() },
            Op::MoveItem { item_id: item.clone(), topic_id: None, tunnel: false },
            Op::RenameTopic { topic_id: old.id.clone(), name: "Renamed".into() },
        ] {
            ops::queue(&conn, op, 40).unwrap();
            assert_eq!(activity(&old.id), 30);
            assert_eq!(list(&conn).unwrap()[0].id, old.id);
        }
        ops::queue(&conn, Op::MoveItem { item_id: item.clone(), topic_id: Some(new.id.clone()), tunnel: false }, 50).unwrap();
        assert_eq!((activity(&old.id), activity(&new.id)), (30, 50));
        assert_eq!(list(&conn).unwrap()[0].id, new.id);
        ops::queue(&conn, Op::MoveItem { item_id: item, topic_id: Some(new.id.clone()), tunnel: false }, 45).unwrap();
        assert_eq!(activity(&new.id), 50);
        picker_topic(&conn, "New", 99).unwrap();
        assert_eq!(activity(&new.id), 50);
    }

    #[test]
    fn create_queues_the_topic_with_a_trimmed_name() {
        let (_d, conn) = fresh();
        let t = create(&conn, "  Mosaic \n", 5).unwrap();
        assert_eq!((t.name.as_str(), t.item_count), ("Mosaic", 0));
        assert!(uuid::Uuid::parse_str(&t.id).is_ok());
        assert!(list(&conn).unwrap().contains(&t));
        let op = &outbox(&conn)[0];
        assert_eq!((op["type"].as_str(), op["topic_id"].as_str(), op["name"].as_str()), (Some("CreateTopic"), Some(t.id.as_str()), Some("Mosaic")));
    }

    #[test]
    fn names_follow_the_servers_rules_and_bad_ones_write_nothing() {
        let (_d, conn) = fresh();
        let too_long = "x".repeat(MAX_TOPIC_NAME_BYTES + 1);
        let too_many_bytes = "é".repeat(101); // 101 characters, 202 bytes
        for name in ["", "   ", "a\0b", too_long.as_str(), too_many_bytes.as_str(), "GYM", "Books", "old", "école"] {
            assert!(create(&conn, name, 5).is_err(), "created {name:.20?}");
            assert!(rename(&conn, "t", name, 5).is_err() || name == "GYM", "renamed to {name:.20?}");
        }
        assert_eq!(outbox(&conn).len(), 1, "only Gym → GYM, its own case, may be queued");
        assert_eq!(
            create(&conn, "BOOKS", 5).unwrap_err(),
            "A Topic named \"books\" already exists"
        );
        create(&conn, &"x".repeat(MAX_TOPIC_NAME_BYTES), 5).unwrap();
        create(&conn, "gone", 5).unwrap(); // a deleted Topic's name is free
    }

    #[test]
    fn picker_topic_creates_a_topic_when_nothing_matches() {
        let (_d, conn) = fresh();
        let t = picker_topic(&conn, "  Mosaic \n", 5).unwrap();
        assert_eq!((t.name.as_str(), t.item_count), ("Mosaic", 0));
        assert!(list(&conn).unwrap().contains(&t));
        let ops = outbox(&conn);
        assert_eq!(ops.len(), 1);
        assert_eq!((ops[0]["type"].as_str(), ops[0]["topic_id"].as_str()), (Some("CreateTopic"), Some(t.id.as_str())));
    }

    #[test]
    fn picker_topic_reuses_an_open_topic_without_queueing_anything() {
        let (_d, conn) = fresh();
        conn.execute("INSERT INTO items (id, topic_id, text, capture_time) VALUES ('1', 't', 'x', 1)", []).unwrap();
        for name in ["gym", " GYM ", "Gym"] {
            let t = picker_topic(&conn, name, 5).unwrap();
            assert_eq!((t.id.as_str(), t.name.as_str(), t.item_count), ("t", "Gym", 1));
        }
        assert_eq!(picker_topic(&conn, "ÉCOLE", 5).unwrap().id, "e");
        assert!(outbox(&conn).is_empty());
    }

    #[test]
    fn picker_topic_refuses_bad_names_and_reuses_existing_topics() {
        let (_d, conn) = fresh();
        assert_eq!(picker_topic(&conn, "old", 5).unwrap().id, "a");
        for name in ["", "   ", "a\0b", "x".repeat(MAX_TOPIC_NAME_BYTES + 1).as_str()] {
            assert!(picker_topic(&conn, name, 5).is_err(), "accepted {name:.20?}");
        }
        assert!(outbox(&conn).is_empty());
        picker_topic(&conn, "gone", 5).unwrap(); // a deleted Topic's name is free
    }

    #[test]
    fn built_in_blank_and_control_names_are_refused_everywhere_and_queue_nothing() {
        let (_d, conn) = fresh();
        for name in ["inbox", " TUNNEL ", "Trash", "all items", "Anywhere", "New Topic", "new topic…", "New Topic...", "\u{200b}", " \u{2060}\u{feff} ", "a\nb", "tab\there"] {
            assert!(create(&conn, name, 5).is_err(), "create accepted {name:?}");
            assert!(rename(&conn, "t", name, 5).is_err(), "rename accepted {name:?}");
            assert!(picker_topic(&conn, name, 5).is_err(), "picker accepted {name:?}");
        }
        assert_eq!(create(&conn, "Inbox", 5).unwrap_err(), "“Inbox” is a built-in name. Pick another.");
        assert!(outbox(&conn).is_empty());
        for name in ["Inbox ideas", "New Topics", "Mom's recipes; DROP TABLE topics"] {
            create(&conn, name, 5).unwrap();
        }
    }

    #[test]
    fn create_still_refuses_a_name_that_exists() {
        let (_d, conn) = fresh();
        assert_eq!(create(&conn, "gym", 5).unwrap_err(), "A Topic named \"Gym\" already exists");
    }

    #[test]
    fn renaming_to_the_same_name_or_case_works() {
        let (_d, conn) = fresh();
        rename(&conn, "b", " books ", 5).unwrap();
        assert!(outbox(&conn).is_empty(), "an unchanged name would overwrite a newer rename from another Device");
        rename(&conn, "b", "Books", 6).unwrap();
        assert_eq!(list(&conn).unwrap()[0].name, "Books");
        assert_eq!(outbox(&conn).len(), 1);
        rename(&conn, "a", "Older", 7).unwrap();
    }

    #[test]
    fn a_deleted_or_unknown_topic_cant_change() {
        let (_d, conn) = fresh();
        for id in ["d", "nope"] {
            assert_eq!(rename(&conn, id, "New", 5).unwrap_err(), "That Topic no longer exists");
            assert!(delete(&conn, id, &Keep::All, 5).is_err());
        }
        assert!(outbox(&conn).is_empty());
    }

    #[test]
    fn require_open_accepts_live_and_refuses_deleted_and_unknown_topics() {
        let (_d, conn) = fresh();
        require_open(&conn, "t").unwrap();
        require_open(&conn, "a").unwrap();
        assert_eq!(require_open(&conn, "d").unwrap_err(), "That Topic no longer exists");
        assert_eq!(require_open(&conn, "nope").unwrap_err(), "That Topic no longer exists");
    }

    #[test]
    fn delete_sends_kept_items_to_the_inbox_and_the_rest_to_trash() {
        for (keep, want_trash) in [
            (Keep::All, vec![]),
            (Keep::None, vec!["1", "2"]),
            // "elsewhere" left the Topic while the list was open; keeping it changes nothing.
            (Keep::Only { ids: vec!["2".into(), "elsewhere".into()] }, vec!["1"]),
        ] {
            let (_d, conn) = fresh();
            conn.execute_batch(
                "INSERT INTO items (id, topic_id, text, capture_time) VALUES ('1', 't', 'x', 1), ('2', 't', 'y', 2), ('elsewhere', NULL, 'z', 3);
                 INSERT INTO items (id, topic_id, text, capture_time, deleted_at) VALUES ('binned', 't', 'w', 4, 4);",
            )
            .unwrap();
            delete(&conn, "t", &keep, 9).unwrap();

            let mut trash: Vec<String> =
                serde_json::from_value(outbox(&conn)[0]["trash"].clone()).unwrap();
            trash.sort();
            assert_eq!(trash, want_trash);
            assert!(list(&conn).unwrap().iter().all(|t| t.id != "t"));
            let left_in_topic: i64 =
                conn.query_row("SELECT count(*) FROM items WHERE topic_id = 't'", [], |r| r.get(0)).unwrap();
            assert_eq!(left_in_topic, 0);
            let elsewhere: Option<i64> =
                conn.query_row("SELECT deleted_at FROM items WHERE id = 'elsewhere'", [], |r| r.get(0)).unwrap();
            assert_eq!(elsewhere, None);
        }
    }
}
