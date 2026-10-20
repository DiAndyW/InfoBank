use chrono::{DateTime, Utc};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize)]
struct Queued {
    id: String,
    at: DateTime<Utc>,
    #[serde(flatten)]
    op: Op,
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum Op {
    CaptureItem { item_id: String, topic_id: Option<String>, text: Option<String>, attachments: Vec<NewAttachment> },
    CreateTopic { topic_id: String, name: String },
    RenameTopic { topic_id: String, name: String },
    ArchiveTopic { topic_id: String },
    UnarchiveTopic { topic_id: String },
    DeleteTopic { topic_id: String, trash: Vec<String> },
    MoveItem { item_id: String, topic_id: Option<String> },
    SetText { item_id: String, text: Option<String>, base_rev: i64 },
    AddAttachment { item_id: String, attachment: NewAttachment },
    RemoveAttachment { item_id: String, attachment_id: String },
    TrashItem { item_id: String },
    RestoreItem { item_id: String },
}

#[derive(Serialize, Deserialize)]
pub struct NewAttachment {
    pub id: String,
    pub filename: String,
    pub mime_type: String,
    pub size_bytes: i64,
}

/// Applies op to the mirror and queues it for push, inside the caller's transaction.
pub fn queue(conn: &Connection, op: Op, now_us: i64) -> Result<(), String> {
    let at = DateTime::from_timestamp_micros(now_us).ok_or("The system clock is out of range")?;
    let queued = Queued { id: uuid::Uuid::new_v4().to_string(), at, op };
    apply(conn, &queued).map_err(|e| e.to_string())?;
    conn.execute("INSERT INTO outbox (op) VALUES (?1)", [serde_json::to_string(&queued).expect("ops serialize")])
        .map_err(|e| e.to_string())?;
    Ok(())
}

pub fn replay(conn: &Connection) -> rusqlite::Result<()> {
    let mut stmt = conn.prepare("SELECT op FROM outbox ORDER BY seq")?;
    let queued = stmt
        .query_map([], |r| {
            let op: String = r.get(0)?;
            serde_json::from_str::<Queued>(&op)
                .map_err(|e| rusqlite::Error::FromSqlConversionFailure(0, rusqlite::types::Type::Text, Box::new(e)))
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    for q in &queued {
        apply(conn, q)?;
    }
    Ok(())
}

fn apply(conn: &Connection, q: &Queued) -> rusqlite::Result<()> {
    let at = q.at.timestamp_micros();
    match &q.op {
        // Capture writes its own rows, and a pull can't hold an Item before it's pushed.
        Op::CaptureItem { .. } => {}
        Op::CreateTopic { topic_id, name } => {
            conn.execute("INSERT INTO topics (id, name) VALUES (?1, ?2) ON CONFLICT (id) DO NOTHING", (topic_id, name))?;
        }
        Op::RenameTopic { topic_id, name } => {
            conn.execute("UPDATE topics SET name = ?2 WHERE id = ?1", (topic_id, name))?;
        }
        Op::ArchiveTopic { topic_id } => {
            conn.execute("UPDATE topics SET archived_at = ?2 WHERE id = ?1", (topic_id, at))?;
        }
        Op::UnarchiveTopic { topic_id } => {
            conn.execute("UPDATE topics SET archived_at = NULL WHERE id = ?1", [topic_id])?;
        }
        Op::DeleteTopic { topic_id, trash } => {
            conn.execute("UPDATE topics SET deleted_at = ?2 WHERE id = ?1", (topic_id, at))?;
            conn.execute(
                "UPDATE items SET deleted_at = ?2
                 WHERE topic_id = ?1 AND deleted_at IS NULL AND id IN (SELECT value FROM json_each(?3))",
                (topic_id, at, serde_json::to_string(trash).expect("a list of strings serializes")),
            )?;
            conn.execute("UPDATE items SET topic_id = NULL WHERE topic_id = ?1", [topic_id])?;
        }
        Op::MoveItem { item_id, topic_id } => {
            conn.execute("UPDATE items SET topic_id = ?2 WHERE id = ?1", (item_id, topic_id))?;
        }
        Op::SetText { item_id, text, .. } => {
            conn.execute("UPDATE items SET text = ?2, deleted_at = NULL, purge_at = NULL WHERE id = ?1", (item_id, text))?;
        }
        Op::AddAttachment { item_id, attachment: a } => {
            // A pull page may have purged the Item while this op waited.
            conn.execute(
                "INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
                 SELECT ?1, ?2, ?3, ?4, ?5, 0, 0 WHERE EXISTS (SELECT 1 FROM items WHERE id = ?2)
                 ON CONFLICT (id) DO NOTHING",
                (&a.id, item_id, &a.filename, &a.mime_type, a.size_bytes),
            )?;
            conn.execute("UPDATE items SET deleted_at = NULL, purge_at = NULL WHERE id = ?1", [item_id])?;
        }
        Op::RemoveAttachment { item_id, attachment_id } => {
            conn.execute("DELETE FROM attachments WHERE id = ?2 AND item_id = ?1", (item_id, attachment_id))?;
        }
        Op::TrashItem { item_id } => {
            conn.execute("UPDATE items SET deleted_at = ?2, purge_at = NULL WHERE id = ?1", (item_id, at))?;
        }
        Op::RestoreItem { item_id } => {
            conn.execute("UPDATE items SET deleted_at = NULL, purge_at = NULL WHERE id = ?1", [item_id])?;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fresh() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let conn = crate::store::open(&dir.path().join("notebank.db")).unwrap();
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
    fn ops_go_out_in_the_servers_format() {
        let (_d, conn) = fresh();
        let at = 1_760_000_000_123_456;
        queue(&conn, Op::MoveItem { item_id: "i".into(), topic_id: None }, at).unwrap();
        queue(&conn, Op::DeleteTopic { topic_id: "t".into(), trash: vec!["i".into()] }, at).unwrap();

        let ops = outbox(&conn);
        assert_eq!(
            ops[0],
            serde_json::json!({"id": ops[0]["id"], "type": "MoveItem", "at": "2025-10-09T08:53:20.123456Z",
                               "item_id": "i", "topic_id": null})
        );
        assert_eq!(
            ops[1],
            serde_json::json!({"id": ops[1]["id"], "type": "DeleteTopic", "at": "2025-10-09T08:53:20.123456Z",
                               "topic_id": "t", "trash": ["i"]})
        );
        assert_ne!(ops[0]["id"], ops[1]["id"]);
        assert!(uuid::Uuid::parse_str(ops[0]["id"].as_str().unwrap()).is_ok());
    }

    #[test]
    fn each_op_changes_the_mirror() {
        let (_d, conn) = fresh();
        conn.execute_batch(
            "INSERT INTO topics (id, name) VALUES ('t', 'Gym'), ('u', 'Work'), ('d', 'Old');
             INSERT INTO items (id, topic_id, text, capture_time) VALUES
                 ('i', NULL, 'a', 1), ('keep', 'd', 'b', 1), ('bin', 'd', 'c', 1);",
        )
        .unwrap();
        queue(&conn, Op::CreateTopic { topic_id: "n".into(), name: "New".into() }, 5).unwrap();
        queue(&conn, Op::RenameTopic { topic_id: "t".into(), name: "Lifting".into() }, 5).unwrap();
        queue(&conn, Op::ArchiveTopic { topic_id: "u".into() }, 7).unwrap();
        queue(&conn, Op::MoveItem { item_id: "i".into(), topic_id: Some("t".into()) }, 5).unwrap();
        queue(&conn, Op::DeleteTopic { topic_id: "d".into(), trash: vec!["bin".into()] }, 9).unwrap();

        let topic = |id: &str| -> (String, Option<i64>, Option<i64>) {
            conn.query_row("SELECT name, archived_at, deleted_at FROM topics WHERE id = ?1", [id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap()
        };
        let item = |id: &str| -> (Option<String>, Option<i64>) {
            conn.query_row("SELECT topic_id, deleted_at FROM items WHERE id = ?1", [id], |r| Ok((r.get(0)?, r.get(1)?)))
                .unwrap()
        };
        assert_eq!(topic("n"), ("New".into(), None, None));
        assert_eq!(topic("t").0, "Lifting");
        assert_eq!(topic("u").1, Some(7));
        assert_eq!(topic("d").2, Some(9));
        assert_eq!(item("i"), (Some("t".into()), None));
        assert_eq!(item("keep"), (None, None));
        assert_eq!(item("bin"), (None, Some(9)));

        queue(&conn, Op::UnarchiveTopic { topic_id: "u".into() }, 8).unwrap();
        assert_eq!(topic("u").1, None);
        assert_eq!(outbox(&conn).len(), 6);
    }

    fn png(id: &str) -> NewAttachment {
        NewAttachment { id: id.into(), filename: format!("{id}.png"), mime_type: "image/png".into(), size_bytes: 3 }
    }

    #[test]
    fn item_edits_go_out_in_the_servers_format() {
        let (_d, conn) = fresh();
        conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 1)", []).unwrap();
        for op in [
            Op::SetText { item_id: "i".into(), text: None, base_rev: 3 },
            Op::AddAttachment { item_id: "i".into(), attachment: png("a") },
            Op::RemoveAttachment { item_id: "i".into(), attachment_id: "a".into() },
            Op::TrashItem { item_id: "i".into() },
            Op::RestoreItem { item_id: "i".into() },
        ] {
            queue(&conn, op, 1).unwrap();
        }
        let bodies: Vec<serde_json::Value> = outbox(&conn)
            .into_iter()
            .map(|mut o| {
                let fields = o.as_object_mut().unwrap();
                fields.remove("id");
                fields.remove("at");
                o
            })
            .collect();
        assert_eq!(
            bodies,
            [
                serde_json::json!({"type": "SetText", "item_id": "i", "text": null, "base_rev": 3}),
                serde_json::json!({"type": "AddAttachment", "item_id": "i",
                                   "attachment": {"id": "a", "filename": "a.png", "mime_type": "image/png", "size_bytes": 3}}),
                serde_json::json!({"type": "RemoveAttachment", "item_id": "i", "attachment_id": "a"}),
                serde_json::json!({"type": "TrashItem", "item_id": "i"}),
                serde_json::json!({"type": "RestoreItem", "item_id": "i"}),
            ]
        );
    }

    #[test]
    fn item_edits_change_the_mirror() {
        let (_d, conn) = fresh();
        conn.execute_batch(
            "INSERT INTO items (id, text, capture_time, deleted_at, purge_at) VALUES ('i', 'old', 1, 5, 99);
             INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES ('old', 'i', 'o.png', 'image/png', 1, 1, 1);",
        )
        .unwrap();
        let item = || -> (Option<String>, Option<i64>, Option<i64>) {
            conn.query_row("SELECT text, deleted_at, purge_at FROM items WHERE id = 'i'", [], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?))
            })
            .unwrap()
        };
        let files = || -> Vec<(String, bool)> {
            let mut stmt = conn.prepare("SELECT id, uploaded FROM attachments ORDER BY id").unwrap();
            stmt.query_map([], |r| Ok((r.get(0)?, r.get(1)?))).unwrap().map(Result::unwrap).collect()
        };

        queue(&conn, Op::SetText { item_id: "i".into(), text: Some("edited".into()), base_rev: 0 }, 10).unwrap();
        assert_eq!(item(), (Some("edited".into()), None, None), "an edit counts as a restore");
        queue(&conn, Op::TrashItem { item_id: "i".into() }, 11).unwrap();
        assert_eq!(item(), (Some("edited".into()), Some(11), None));
        queue(&conn, Op::AddAttachment { item_id: "i".into(), attachment: png("new") }, 12).unwrap();
        assert_eq!(item().1, None, "adding a file counts as a restore");
        assert_eq!(files(), [("new".into(), false), ("old".into(), true)]);
        queue(&conn, Op::RemoveAttachment { item_id: "other".into(), attachment_id: "new".into() }, 13).unwrap();
        queue(&conn, Op::RemoveAttachment { item_id: "i".into(), attachment_id: "old".into() }, 13).unwrap();
        assert_eq!(files(), [("new".into(), false)]);
        queue(&conn, Op::TrashItem { item_id: "i".into() }, 14).unwrap();
        queue(&conn, Op::RestoreItem { item_id: "i".into() }, 15).unwrap();
        assert_eq!(item(), (Some("edited".into()), None, None));
    }

    #[test]
    fn a_file_added_to_an_item_that_is_gone_is_skipped() {
        let (_d, conn) = fresh();
        queue(&conn, Op::AddAttachment { item_id: "gone".into(), attachment: png("a") }, 1).unwrap();
        let n: i64 = conn.query_row("SELECT count(*) FROM attachments", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 0);
    }
}
