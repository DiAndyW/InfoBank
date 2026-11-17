use rusqlite::Connection;
use serde::Serialize;

#[derive(Serialize, Debug, PartialEq)]
pub struct Draft {
    pub attachments: Vec<crate::files::Staged>,
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
    let rows: Vec<Draft> = conn.prepare(
        "SELECT place, text, (SELECT id FROM topics WHERE id = drafts.home_topic_id AND deleted_at IS NULL) FROM drafts",
    ).and_then(|mut stmt| stmt.query_map([], |r| Ok(Draft { attachments: vec![], place: r.get(0)?, text: r.get(1)?, home_topic_id: r.get(2)? }))?.collect())
        .map_err(crate::error_message::message)?;
    rows.into_iter().map(|mut draft| {
        draft.attachments = conn.prepare("SELECT attachment_id, filename, mime_type, size_bytes FROM draft_attachments WHERE place = ?1 ORDER BY position")
            .and_then(|mut stmt| stmt.query_map([&draft.place], |r| Ok(crate::files::Staged { id: r.get(0)?, filename: r.get(1)?, mime_type: r.get(2)?, size_bytes: r.get::<_, i64>(3)? as u64 }))?.collect())
            .map_err(crate::error_message::message)?;
        Ok(draft)
    }).collect()
}

#[cfg(test)]
pub fn save(conn: &Connection, place: &str, text: &str, home_topic_id: Option<&str>) -> Result<(), String> {
    if text.trim().is_empty() && !conn.query_row("SELECT EXISTS(SELECT 1 FROM draft_attachments WHERE place = ?1)", [place], |r| r.get::<_, bool>(0)).map_err(crate::error_message::message)? {
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

pub fn save_with_attachments(conn: &Connection, dir: &std::path::Path, place: &str, text: &str, home_topic_id: Option<&str>, attachment_ids: &[String]) -> Result<(), String> {
    let tx = conn.unchecked_transaction().map_err(crate::error_message::message)?;
    let mut attachments = Vec::new();
    for id in attachment_ids {
        crate::files::require_unowned(&tx, id, Some(place))?;
        let existing = tx.query_row("SELECT filename, mime_type, size_bytes FROM draft_attachments WHERE attachment_id = ?1 AND place = ?2", (id, place), |r| Ok(crate::files::Staged { id: id.clone(), filename: r.get(0)?, mime_type: r.get(1)?, size_bytes: r.get::<_, i64>(2)? as u64 }));
        let attachment = match existing {
            Ok(a) => a,
            Err(rusqlite::Error::QueryReturnedNoRows) => {
                let (filename, size_bytes) = crate::files::staged_file(dir, id)?;
                if size_bytes > crate::files::MAX_ATTACHMENT_BYTES { return Err("Attachment is over 100 MB".into()); }
                let path = dir.join("files").join(id).join(&filename);
                std::fs::OpenOptions::new().write(true).open(&path).and_then(|f| f.sync_all()).map_err(|_| "Attachment failed to save")?;
                #[cfg(unix)]
                std::fs::File::open(path.parent().unwrap()).and_then(|f| f.sync_all()).map_err(|_| "Attachment failed to save")?;
                #[cfg(unix)]
                std::fs::File::open(dir.join("files")).and_then(|f| f.sync_all()).map_err(|_| "Attachment failed to save")?;
                crate::files::Staged { id: id.clone(), mime_type: crate::files::mime_type(&filename), filename, size_bytes }
            },
            Err(e) => return Err(crate::error_message::message(e)),
        };
        attachments.push(attachment);
    }
    tx.execute("DELETE FROM draft_attachments WHERE place = ?1", [place]).map_err(crate::error_message::message)?;
    if text.trim().is_empty() && attachments.is_empty() {
        tx.execute("DELETE FROM drafts WHERE place = ?1", [place]).map_err(crate::error_message::message)?;
    } else {
        tx.execute("INSERT INTO drafts(place,text,home_topic_id) VALUES (?1,?2,?3) ON CONFLICT(place) DO UPDATE SET text=excluded.text, home_topic_id=excluded.home_topic_id", (place,text,if place == "home" { home_topic_id } else { None })).map_err(crate::error_message::message)?;
        for (position,a) in attachments.iter().enumerate() {
            tx.execute("INSERT INTO draft_attachments VALUES (?1,?2,?3,?4,?5,?6)", (&a.id,place,position as i64,&a.filename,&a.mime_type,a.size_bytes as i64)).map_err(crate::error_message::message)?;
        }
    }
    tx.commit().map_err(crate::error_message::message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store;

    #[test]
    fn drafts_each_place_detaches_before_bytes_and_failed_save_keeps_owner() {
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("notebank.db");
        let conn = store::open(&path).unwrap();
        conn.execute("INSERT INTO topics(id,name) VALUES ('t','Topic')", []).unwrap();
        let mut expected = Vec::new();
        for place in ["home", "inbox", "tunnel", "topic:t"] {
            let a = crate::files::stage_bytes(d.path(), "a.txt", b"bytes").unwrap();
            save_with_attachments(&conn, d.path(), place, "", None, &[a.id.clone()]).unwrap();
            expected.push((place.to_string(), a));
        }
        drop(conn);
        let conn = store::open(&path).unwrap();
        crate::files::sweep_staged(&conn, d.path()).unwrap();
        for (place, a) in expected {
            assert_eq!(list(&conn).unwrap().into_iter().find(|d| d.place == place).unwrap().attachments, vec![a.clone()]);
            conn.execute_batch("CREATE TRIGGER refuse BEFORE DELETE ON draft_attachments BEGIN SELECT RAISE(ABORT, 'fail'); END;").unwrap();
            assert!(save_with_attachments(&conn, d.path(), &place, "", None, &[]).is_err());
            assert!(crate::files::unstage(&conn, d.path(), &a.id).is_err());
            assert!(crate::files::staged_file(d.path(), &a.id).is_ok());
            conn.execute_batch("DROP TRIGGER refuse").unwrap();
            save_with_attachments(&conn, d.path(), &place, "", None, &[]).unwrap();
            assert!(crate::files::staged_file(d.path(), &a.id).is_ok());
            crate::files::unstage(&conn, d.path(), &a.id).unwrap();
            assert!(crate::files::staged_file(d.path(), &a.id).is_err());
        }
    }

    #[test]
    fn drafts_owned_files_restore_and_enforce_consumption() {
        use crate::{files, feed, cache};
        let d = tempfile::tempdir().unwrap();
        let path = d.path().join("notebank.db");
        let conn = store::open(&path).unwrap();
        let a = files::stage_bytes(d.path(), "a.txt", b"one").unwrap();
        let b = files::stage_bytes(d.path(), "b.txt", b"two").unwrap();
        let transient = files::stage_bytes(d.path(), "edit.txt", b"edit").unwrap();
        let ids = vec![b.id.clone(), a.id.clone()];
        save_with_attachments(&conn, d.path(), "home", "", None, &ids).unwrap();
        save(&conn, "home", "", None).unwrap();
        assert!(save_with_attachments(&conn, d.path(), "inbox", "", None, &ids).is_err());
        assert!(files::unstage(&conn, d.path(), &a.id).is_err());
        for source in [None, Some("inbox")] {
            assert!(feed::capture(&conn, d.path(), "", &ids, &feed::Target::Inbox, source, 1).is_err());
        }
        feed::capture(&conn, d.path(), "editor", &[], &feed::Target::Inbox, None, 1).unwrap();
        let item: String = conn.query_row("SELECT id FROM items", [], |r| r.get(0)).unwrap();
        assert!(feed::edit_item(&conn, d.path(), &item, "edit", &ids, &[], 0, 2).is_err());
        drop(conn);
        let conn = store::open(&path).unwrap();
        files::sweep_staged(&conn, d.path()).unwrap();
        cache::evict(&conn, d.path(), 100, 0).unwrap();
        assert_eq!(list(&conn).unwrap()[0].attachments, vec![b.clone(), a.clone()]);
        assert!(files::staged_file(d.path(), &transient.id).is_err());
        conn.execute_batch("CREATE TRIGGER refuse BEFORE INSERT ON outbox BEGIN SELECT RAISE(ABORT, 'fail'); END;").unwrap();
        assert!(feed::capture(&conn, d.path(), "", &ids, &feed::Target::Inbox, Some("home"), 3).is_err());
        assert_eq!(list(&conn).unwrap()[0].attachments.len(), 2);
        assert!(files::staged_file(d.path(), &a.id).is_ok());
        conn.execute_batch("DROP TRIGGER refuse").unwrap();
        std::fs::remove_dir_all(d.path().join("files").join(&a.id)).unwrap();
        assert_eq!(list(&conn).unwrap()[0].attachments.len(), 2);
        assert!(feed::capture(&conn, d.path(), "", &ids, &feed::Target::Inbox, Some("home"), 4).is_err());
        save_with_attachments(&conn, d.path(), "home", "", None, &[b.id.clone()]).unwrap();
        feed::capture(&conn, d.path(), "", &[b.id.clone()], &feed::Target::Inbox, Some("home"), 5).unwrap();
        assert!(list(&conn).unwrap().is_empty());
        assert!(files::staged_file(d.path(), &b.id).is_ok());
        assert!(save_with_attachments(&conn, d.path(), "home", "", None, &[b.id]).is_err());
        save_with_attachments(&conn, d.path(), "home", "", None, &[]).unwrap();
        assert!(list(&conn).unwrap().is_empty());
    }

    #[test]
    fn drafts_migration_supports_attachment_only_rows() {
        let dir = tempfile::tempdir().unwrap();
        let conn = store::open(&dir.path().join("notebank.db")).unwrap();
        assert!(conn.execute("INSERT INTO drafts(place,text) VALUES ('inbox','')", []).is_ok(), "attachment-only drafts require blank text");
        assert!(conn.prepare("SELECT attachment_id, place, position FROM draft_attachments").is_ok(), "durable ownership relation must exist");
    }

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
                Draft { attachments: vec![], place: "home".into(), text: "a".into(), home_topic_id: Some("t1".into()) },
                Draft { attachments: vec![], place: "inbox".into(), text: "b".into(), home_topic_id: None },
                Draft { attachments: vec![], place: "topic:t1".into(), text: "c".into(), home_topic_id: None },
            ]
        );
        save(&conn, "home", " updated ", None).unwrap();
        save(&conn, "tunnel", "transfer", None).unwrap();
        let drafts = list(&conn).unwrap();
        assert!(drafts.contains(&Draft { attachments: vec![], place: "home".into(), text: " updated ".into(), home_topic_id: None }));
        assert!(drafts.contains(&Draft { attachments: vec![], place: "tunnel".into(), text: "transfer".into(), home_topic_id: None }));
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
        assert_eq!(list(&conn).unwrap(), vec![Draft { attachments: vec![], place: "inbox".into(), text: "b".into(), home_topic_id: None }]);
    }

    #[test]
    fn list_drops_drafts_of_deleted_or_missing_topics_but_keeps_live() {
        let dir = tempfile::tempdir().unwrap();
        let conn = store::open(&dir.path().join("notebank.db")).unwrap();
        conn.execute_batch(
            "INSERT INTO topics (id, name) VALUES ('live', 'Live');
            INSERT INTO topics (id, name) VALUES ('other', 'Other');
            INSERT INTO topics (id, name, deleted_at) VALUES ('gone', 'Gone', 1);",
        )
        .unwrap();
        for place in ["topic:live", "topic:other", "topic:gone", "topic:nope"] {
            save(&conn, place, "draft", None).unwrap();
        }
        let mut drafts = list(&conn).unwrap();
        drafts.sort_by(|a, b| a.place.cmp(&b.place));
        assert_eq!(
            drafts,
            vec![
                Draft { attachments: vec![], place: "topic:live".into(), text: "draft".into(), home_topic_id: None },
                Draft { attachments: vec![], place: "topic:other".into(), text: "draft".into(), home_topic_id: None },
            ]
        );
        let remaining: i64 = conn.query_row("SELECT count(*) FROM drafts", [], |r| r.get(0)).unwrap();
        assert_eq!(remaining, 2);
    }

    #[test]
    fn home_topic_reads_as_inbox_unless_that_topic_is_live() {
        let dir = tempfile::tempdir().unwrap();
        let conn = store::open(&dir.path().join("notebank.db")).unwrap();
        conn.execute_batch(
            "INSERT INTO topics (id, name) VALUES ('live', 'Live');
            INSERT INTO topics (id, name) VALUES ('other', 'Other');
            INSERT INTO topics (id, name, deleted_at) VALUES ('gone', 'Gone', 1);",
        )
        .unwrap();
        for (topic, expected) in [("live", Some("live")), ("other", Some("other")), ("gone", None), ("nope", None)] {
            save(&conn, "home", "draft", Some(topic)).unwrap();
            assert_eq!(list(&conn).unwrap()[0].home_topic_id.as_deref(), expected, "{topic}");
        }
    }
}
