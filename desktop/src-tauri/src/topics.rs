use rusqlite::{Connection, OptionalExtension};
use serde::{Deserialize, Serialize};

use crate::ops::{self, Op};

// The Server's limit, so it never rejects a name.
const MAX_TOPIC_NAME_BYTES: usize = 200;

#[derive(Serialize, Debug, PartialEq)]
pub struct Topic {
    pub id: String,
    pub name: String,
    pub archived: bool,
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
        "SELECT t.id, t.name, t.archived_at IS NOT NULL,
                (SELECT count(*) FROM items i WHERE i.topic_id = t.id AND i.deleted_at IS NULL)
         FROM topics t WHERE t.deleted_at IS NULL ORDER BY lower(t.name), t.id",
    )?;
    stmt.query_map([], |r| Ok(Topic { id: r.get(0)?, name: r.get(1)?, archived: r.get(2)?, item_count: r.get(3)? }))?
        .collect()
}

fn archived(conn: &Connection, id: &str) -> Result<bool, String> {
    conn.query_row("SELECT archived_at IS NOT NULL FROM topics WHERE id = ?1 AND deleted_at IS NULL", [id], |r| r.get(0))
        .optional()
        .map_err(|e| e.to_string())?
        .ok_or_else(|| "That Topic no longer exists".to_string())
}

pub fn require_open(conn: &Connection, id: &str) -> Result<(), String> {
    if archived(conn, id)? {
        return Err("That Topic is archived".into());
    }
    Ok(())
}

fn checked_name(conn: &Connection, name: &str, own_id: &str) -> Result<String, String> {
    let name = name.trim();
    if name.is_empty() {
        return Err("Give the Topic a name".into());
    }
    if name.len() > MAX_TOPIC_NAME_BYTES {
        return Err("That name is too long (200 bytes max)".into());
    }
    if name.contains('\0') {
        return Err("That name contains a character that can't be saved".into());
    }
    let mut stmt = conn.prepare("SELECT name FROM topics WHERE deleted_at IS NULL AND id <> ?1").map_err(|e| e.to_string())?;
    let taken = stmt
        .query_map([own_id], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
    // SQLite's lower() only folds ASCII.
    if let Some(other) = taken.iter().find(|t| t.to_lowercase() == name.to_lowercase()) {
        return Err(format!("A Topic named \"{other}\" already exists"));
    }
    Ok(name.to_string())
}

fn queue_one(conn: &Connection, op: Op, now_us: i64) -> Result<(), String> {
    let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
    ops::queue(&tx, op, now_us)?;
    tx.commit().map_err(|e| e.to_string())
}

pub fn create(conn: &Connection, name: &str, now_us: i64) -> Result<Topic, String> {
    let id = uuid::Uuid::new_v4().to_string();
    let name = checked_name(conn, name, &id)?;
    queue_one(conn, Op::CreateTopic { topic_id: id.clone(), name: name.clone() }, now_us)?;
    Ok(Topic { id, name, archived: false, item_count: 0 })
}

pub fn rename(conn: &Connection, id: &str, name: &str, now_us: i64) -> Result<(), String> {
    archived(conn, id)?;
    let name = checked_name(conn, name, id)?;
    let current: String =
        conn.query_row("SELECT name FROM topics WHERE id = ?1", [id], |r| r.get(0)).map_err(|e| e.to_string())?;
    // A fresh stamp on an unchanged name would win over a newer rename from another Device.
    if name == current {
        return Ok(());
    }
    queue_one(conn, Op::RenameTopic { topic_id: id.into(), name }, now_us)
}

pub fn set_archived(conn: &Connection, id: &str, archived_now: bool, now_us: i64) -> Result<(), String> {
    archived(conn, id)?;
    let topic_id = id.to_string();
    let op = if archived_now { Op::ArchiveTopic { topic_id } } else { Op::UnarchiveTopic { topic_id } };
    queue_one(conn, op, now_us)
}

pub fn delete(conn: &Connection, id: &str, keep: &Keep, now_us: i64) -> Result<(), String> {
    archived(conn, id)?;
    let mut stmt =
        conn.prepare("SELECT id FROM items WHERE topic_id = ?1 AND deleted_at IS NULL").map_err(|e| e.to_string())?;
    let ids = stmt
        .query_map([id], |r| r.get::<_, String>(0))
        .map_err(|e| e.to_string())?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(|e| e.to_string())?;
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
             INSERT INTO topics (id, name, archived_at) VALUES ('a', 'Old', 1);
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
    fn list_shows_archived_topics_and_counts_items_outside_trash() {
        let (_d, conn) = fresh();
        conn.execute_batch(
            "INSERT INTO items (id, topic_id, text, capture_time) VALUES ('1', 't', 'x', 1), ('2', 't', 'y', 1);
             INSERT INTO items (id, topic_id, text, capture_time, deleted_at) VALUES ('3', 't', 'z', 1, 2);",
        )
        .unwrap();
        let summary: Vec<(String, bool, i64)> =
            list(&conn).unwrap().into_iter().map(|t| (t.name, t.archived, t.item_count)).collect();
        // SQLite's lower() leaves É alone, so non-ASCII initials sort after Z; fine for v1.
        assert_eq!(
            summary,
            [("books".into(), false, 0), ("Gym".into(), false, 2), ("Old".into(), true, 0), ("École".into(), false, 0)]
        );
    }

    #[test]
    fn create_queues_the_topic_with_a_trimmed_name() {
        let (_d, conn) = fresh();
        let t = create(&conn, "  Mosaic \n", 5).unwrap();
        assert_eq!((t.name.as_str(), t.archived, t.item_count), ("Mosaic", false, 0));
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
    fn renaming_to_the_same_name_or_case_works() {
        let (_d, conn) = fresh();
        rename(&conn, "b", " books ", 5).unwrap();
        assert!(outbox(&conn).is_empty(), "an unchanged name would overwrite a newer rename from another Device");
        rename(&conn, "b", "Books", 6).unwrap();
        assert_eq!(list(&conn).unwrap()[0].name, "Books");
        assert_eq!(outbox(&conn).len(), 1);
        rename(&conn, "a", "Older", 7).unwrap(); // archived Topics can be renamed
    }

    #[test]
    fn archive_and_unarchive() {
        let (_d, conn) = fresh();
        set_archived(&conn, "t", true, 5).unwrap();
        assert!(list(&conn).unwrap().iter().find(|t| t.id == "t").unwrap().archived);
        set_archived(&conn, "t", false, 6).unwrap();
        assert!(!list(&conn).unwrap().iter().find(|t| t.id == "t").unwrap().archived);
        let types: Vec<_> = outbox(&conn).iter().map(|o| o["type"].as_str().unwrap().to_string()).collect();
        assert_eq!(types, ["ArchiveTopic", "UnarchiveTopic"]);
    }

    #[test]
    fn a_deleted_or_unknown_topic_cant_change() {
        let (_d, conn) = fresh();
        for id in ["d", "nope"] {
            assert_eq!(rename(&conn, id, "New", 5).unwrap_err(), "That Topic no longer exists");
            assert!(set_archived(&conn, id, true, 5).is_err());
            assert!(delete(&conn, id, &Keep::All, 5).is_err());
        }
        assert!(outbox(&conn).is_empty());
    }

    #[test]
    fn require_open_refuses_archived_deleted_and_unknown_topics() {
        let (_d, conn) = fresh();
        require_open(&conn, "t").unwrap();
        assert_eq!(require_open(&conn, "a").unwrap_err(), "That Topic is archived");
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
