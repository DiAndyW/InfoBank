use rusqlite::Connection;
use serde::Serialize;

#[derive(Serialize, Debug, PartialEq)]
pub struct Draft {
    pub place: String,
    pub text: String,
    pub home_topic_id: Option<String>,
}

pub fn list(conn: &Connection) -> Result<Vec<Draft>, String> {
    conn.execute(
        "DELETE FROM drafts WHERE place LIKE 'topic:_%'
         AND NOT EXISTS (SELECT 1 FROM topics WHERE id = substr(drafts.place, 7) AND deleted_at IS NULL)",
        [],
    )
    .map_err(crate::error_message::message)?;
    conn.prepare(
        "SELECT place, text, (SELECT id FROM topics WHERE id = drafts.home_topic_id AND deleted_at IS NULL AND archived_at IS NULL)
         FROM drafts",
    )
        .and_then(|mut stmt| stmt.query_map([], |r| Ok(Draft { place: r.get(0)?, text: r.get(1)?, home_topic_id: r.get(2)? }))?.collect())
        .map_err(crate::error_message::message)
}

pub fn save(conn: &Connection, place: &str, text: &str, home_topic_id: Option<&str>) -> Result<(), String> {
    if text.trim().is_empty() {
        conn.execute("DELETE FROM drafts WHERE place = ?1", [place])
    } else {
        conn.execute(
            "INSERT INTO drafts (place, text, home_topic_id) VALUES (?1, ?2, ?3)
             ON CONFLICT (place) DO UPDATE SET text = excluded.text, home_topic_id = excluded.home_topic_id",
            (place, text, home_topic_id),
        )
    }
    .map(|_| ())
    .map_err(crate::error_message::message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store;

    #[test]
    fn database_failure_is_plain() {
        let conn = Connection::open_in_memory().unwrap();
        assert_eq!(save(&conn, "inbox", "keep", None).unwrap_err(), "NoteBank couldn't read or save its data. Try again.");
    }

    #[test]
    fn save_then_list_round_trips_each_place() {
        let dir = tempfile::tempdir().unwrap();
        let conn = store::open(&dir.path().join("notebank.db")).unwrap();
        conn.execute("INSERT INTO topics (id, name) VALUES ('t1', 'Topic')", []).unwrap();
        save(&conn, "home", "a", Some("t1")).unwrap();
        save(&conn, "inbox", "b", None).unwrap();
        save(&conn, "topic:t1", "c", None).unwrap();
        let mut drafts = list(&conn).unwrap();
        drafts.sort_by(|a, b| a.place.cmp(&b.place));
        assert_eq!(
            drafts,
            vec![
                Draft { place: "home".into(), text: "a".into(), home_topic_id: Some("t1".into()) },
                Draft { place: "inbox".into(), text: "b".into(), home_topic_id: None },
                Draft { place: "topic:t1".into(), text: "c".into(), home_topic_id: None },
            ]
        );
        save(&conn, "home", " updated ", None).unwrap();
        save(&conn, "tunnel", "transfer", None).unwrap();
        let drafts = list(&conn).unwrap();
        assert!(drafts.contains(&Draft { place: "home".into(), text: " updated ".into(), home_topic_id: None }));
        assert!(drafts.contains(&Draft { place: "tunnel".into(), text: "transfer".into(), home_topic_id: None }));
        assert_eq!(drafts.len(), 4);
        let queued: i64 = conn.query_row("SELECT count(*) FROM outbox", [], |r| r.get(0)).unwrap();
        assert_eq!(queued, 0);
    }

    #[test]
    fn blank_text_deletes_the_draft() {
        let dir = tempfile::tempdir().unwrap();
        let conn = store::open(&dir.path().join("notebank.db")).unwrap();
        save(&conn, "inbox", "b", None).unwrap();
        save(&conn, "inbox", "  \n", None).unwrap();
        assert!(list(&conn).unwrap().is_empty());
    }

    #[test]
    fn drafts_survive_reopening_the_database() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("notebank.db");
        let conn = store::open(&path).unwrap();
        save(&conn, "inbox", "b", None).unwrap();
        drop(conn);
        let conn = store::open(&path).unwrap();
        assert_eq!(list(&conn).unwrap(), vec![Draft { place: "inbox".into(), text: "b".into(), home_topic_id: None }]);
    }

    #[test]
    fn list_drops_drafts_of_deleted_or_missing_topics_but_keeps_archived() {
        let dir = tempfile::tempdir().unwrap();
        let conn = store::open(&dir.path().join("notebank.db")).unwrap();
        conn.execute_batch(
            "INSERT INTO topics (id, name) VALUES ('live', 'Live');
            INSERT INTO topics (id, name, archived_at) VALUES ('archived', 'Archived', 1);
            INSERT INTO topics (id, name, deleted_at) VALUES ('gone', 'Gone', 1);",
        )
        .unwrap();
        for place in ["topic:live", "topic:archived", "topic:gone", "topic:nope"] {
            save(&conn, place, "draft", None).unwrap();
        }
        let mut drafts = list(&conn).unwrap();
        drafts.sort_by(|a, b| a.place.cmp(&b.place));
        assert_eq!(
            drafts,
            vec![
                Draft { place: "topic:archived".into(), text: "draft".into(), home_topic_id: None },
                Draft { place: "topic:live".into(), text: "draft".into(), home_topic_id: None },
            ]
        );
        let remaining: i64 = conn.query_row("SELECT count(*) FROM drafts", [], |r| r.get(0)).unwrap();
        assert_eq!(remaining, 2);
    }

    #[test]
    fn home_topic_reads_as_inbox_unless_that_topic_is_open() {
        let dir = tempfile::tempdir().unwrap();
        let conn = store::open(&dir.path().join("notebank.db")).unwrap();
        conn.execute_batch(
            "INSERT INTO topics (id, name) VALUES ('live', 'Live');
            INSERT INTO topics (id, name, archived_at) VALUES ('archived', 'Archived', 1);
            INSERT INTO topics (id, name, deleted_at) VALUES ('gone', 'Gone', 1);",
        )
        .unwrap();
        for (topic, expected) in [("live", Some("live")), ("archived", None), ("gone", None), ("nope", None)] {
            save(&conn, "home", "draft", Some(topic)).unwrap();
            assert_eq!(list(&conn).unwrap()[0].home_topic_id.as_deref(), expected, "{topic}");
        }
    }
}
