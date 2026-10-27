import GRDB

extension DatabaseMigrator {
    static var noteBank: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE topics (
                    id          TEXT PRIMARY KEY,
                    name        TEXT NOT NULL CHECK (trim(name) <> ''),
                    archived_at INTEGER,
                    deleted_at  INTEGER
                ) STRICT;

                CREATE TABLE items (
                    id           TEXT PRIMARY KEY,
                    topic_id     TEXT,
                    text         TEXT CHECK (text <> ''),
                    capture_time INTEGER NOT NULL,
                    deleted_at   INTEGER,
                    purge_at     INTEGER,
                    text_rev     INTEGER NOT NULL DEFAULT 0,
                    sync_error   TEXT
                ) STRICT;
                CREATE INDEX items_topic_capture_time ON items (topic_id, capture_time, id);
                CREATE INDEX items_capture_time ON items (capture_time, id);

                CREATE TABLE attachments (
                    id            TEXT PRIMARY KEY,
                    item_id       TEXT NOT NULL REFERENCES items (id) ON DELETE CASCADE,
                    filename      TEXT NOT NULL,
                    mime_type     TEXT NOT NULL,
                    size_bytes    INTEGER NOT NULL CHECK (size_bytes >= 0),
                    uploaded      INTEGER NOT NULL CHECK (uploaded IN (0, 1)),
                    has_thumbnail INTEGER NOT NULL CHECK (has_thumbnail IN (0, 1))
                ) STRICT;
                CREATE INDEX attachments_item ON attachments (item_id);

                CREATE TABLE outbox (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT,
                    op  TEXT NOT NULL
                ) STRICT;
                CREATE INDEX outbox_item ON outbox (json_extract(op, '$.item_id'));

                CREATE TABLE device (
                    id          INTEGER PRIMARY KEY CHECK (id = 1),
                    device_id   TEXT NOT NULL,
                    server_url  TEXT,
                    pull_cursor INTEGER NOT NULL DEFAULT 0
                ) STRICT;
                """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE items ADD COLUMN in_tunnel INTEGER NOT NULL DEFAULT 0
                    CHECK (in_tunnel IN (0, 1) AND NOT (in_tunnel = 1 AND topic_id IS NOT NULL));
                """)
        }
        migrator.registerMigration("v3") { db in
            try db.execute(sql: """
                CREATE TABLE settings (
                    id               INTEGER PRIMARY KEY CHECK (id = 1),
                    trash_after_copy INTEGER CHECK (trash_after_copy IN (0, 1))
                ) STRICT;
                INSERT INTO settings (id) VALUES (1);
                """)
        }
        return migrator
    }
}
