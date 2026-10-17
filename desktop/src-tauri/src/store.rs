use std::path::Path;

use rusqlite::Connection;

const MIGRATIONS: &[&str] = &[
    include_str!("../migrations/0001_init.sql"),
    include_str!("../migrations/0002_feed.sql"),
    include_str!("../migrations/0003_cache.sql"),
    include_str!("../migrations/0004_outbox_item.sql"),
];

pub fn open(path: &Path) -> rusqlite::Result<Connection> {
    let conn = Connection::open(path)?;
    // SQLite turns foreign keys off for every new connection.
    conn.pragma_update(None, "foreign_keys", true)?;
    let version: i64 = conn.pragma_query_value(None, "user_version", |r| r.get(0))?;
    for (i, sql) in MIGRATIONS.iter().enumerate().skip(version as usize) {
        let tx = conn.unchecked_transaction()?;
        tx.execute_batch(sql)?;
        tx.pragma_update(None, "user_version", (i + 1) as i64)?;
        tx.commit()?;
    }
    conn.execute(
        "INSERT INTO device (id, device_id) VALUES (1, ?1) ON CONFLICT (id) DO NOTHING",
        [uuid::Uuid::new_v4().to_string()],
    )?;
    Ok(conn)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn device_id(conn: &Connection) -> rusqlite::Result<String> {
        conn.query_row("SELECT device_id FROM device", [], |r| r.get(0))
    }

    #[test]
    fn reopening_keeps_device_id_and_skips_migrations() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("notebank.db");

        let first = open(&path).unwrap();
        let id = device_id(&first).unwrap();
        assert!(uuid::Uuid::parse_str(&id).is_ok(), "device_id {id} is not a UUID");
        drop(first);

        // A re-run of 0001 would fail on CREATE TABLE, so a clean reopen proves it was skipped.
        let again = open(&path).unwrap();
        assert_eq!(device_id(&again).unwrap(), id);
        let version: i64 = again.pragma_query_value(None, "user_version", |r| r.get(0)).unwrap();
        assert_eq!(version, MIGRATIONS.len() as i64);
        let rows: i64 = again.query_row("SELECT count(*) FROM device", [], |r| r.get(0)).unwrap();
        assert_eq!(rows, 1);
    }

    #[test]
    fn device_table_holds_one_row() {
        let dir = tempfile::tempdir().unwrap();
        let conn = open(&dir.path().join("notebank.db")).unwrap();
        let second = conn.execute("INSERT INTO device (id, device_id) VALUES (2, 'x')", []);
        assert_eq!(
            second.unwrap_err().sqlite_error_code(),
            Some(rusqlite::ErrorCode::ConstraintViolation),
            "a second device row must break a constraint"
        );
    }

    fn fresh() -> (tempfile::TempDir, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let conn = open(&dir.path().join("notebank.db")).unwrap();
        (dir, conn)
    }

    #[test]
    fn empty_text_is_rejected() {
        let (_dir, conn) = fresh();
        let res = conn.execute("INSERT INTO items (id, text, capture_time) VALUES ('i', '', 0)", []);
        assert_eq!(
            res.unwrap_err().sqlite_error_code(),
            Some(rusqlite::ErrorCode::ConstraintViolation),
            "an Item with empty text was accepted; no text must be NULL"
        );
    }

    #[test]
    fn deleting_an_item_deletes_its_attachments() {
        let (_dir, conn) = fresh();
        conn.execute_batch(
            "INSERT INTO items (id, text, capture_time) VALUES ('i', 'x', 0);
             INSERT INTO attachments (id, item_id, filename, mime_type, size_bytes, uploaded, has_thumbnail)
             VALUES ('a', 'i', 'a.png', 'image/png', 1, 1, 0);
             DELETE FROM items WHERE id = 'i';",
        )
        .unwrap();
        let left: i64 = conn.query_row("SELECT count(*) FROM attachments", [], |r| r.get(0)).unwrap();
        assert_eq!(left, 0);
    }
}
