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
        migrator.registerMigration("v4") { db in
            try db.execute(sql: """
                CREATE TABLE conflicts (
                    item_id TEXT PRIMARY KEY REFERENCES items(id) ON DELETE CASCADE,
                    text TEXT,
                    mine INTEGER NOT NULL CHECK(mine IN (0, 1))
                ) STRICT;
                """)
        }
        migrator.registerMigration("v5") { db in
            try db.execute(sql: """
                ALTER TABLE device ADD COLUMN transfer_generation INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE items ADD COLUMN opened_at INTEGER NOT NULL DEFAULT 0;
                CREATE TABLE staged_files (
                    id TEXT PRIMARY KEY, filename TEXT NOT NULL, mime_type TEXT NOT NULL,
                    size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0), created_at INTEGER NOT NULL
                ) STRICT;
                CREATE TABLE cached_files (
                    attachment_id TEXT NOT NULL, kind TEXT NOT NULL CHECK(kind IN ('file', 'thumbnail')),
                    path TEXT NOT NULL, size_bytes INTEGER NOT NULL CHECK(size_bytes >= 0), last_used_at INTEGER NOT NULL,
                    PRIMARY KEY(attachment_id, kind)
                ) STRICT;
                CREATE TABLE attachment_uploads (
                    attachment_id TEXT PRIMARY KEY REFERENCES attachments(id) ON DELETE CASCADE,
                    server_url TEXT NOT NULL, task_id INTEGER NOT NULL, generation INTEGER NOT NULL, error TEXT NOT NULL DEFAULT '', retry_at INTEGER NOT NULL DEFAULT 0, attempts INTEGER NOT NULL DEFAULT 0
                ) STRICT;
                """)
        }
        migrator.registerMigration("v6") { db in
            try db.execute(sql: """
                ALTER TABLE attachment_uploads ADD COLUMN session_identifier TEXT NOT NULL DEFAULT 'app.notebank.ios.attachment-uploads';
                CREATE TABLE file_sessions (id TEXT PRIMARY KEY, process_id INTEGER NOT NULL CHECK(process_id > 0)) STRICT;
                """)
        }
        migrator.registerMigration("v7") { db in
            try db.execute(sql: """
                -- Every Item, Trash included; search joins items for its filters. rowid = items.rowid, which holds because nothing runs VACUUM.
                CREATE VIRTUAL TABLE search USING fts5(text, names, tokenize = 'trigram remove_diacritics 1');

                CREATE VIEW item_names AS
                    SELECT item_id, group_concat(filename, char(10)) AS names
                    FROM (SELECT item_id, filename FROM attachments ORDER BY rowid)
                    GROUP BY item_id;

                CREATE TRIGGER search_item_added AFTER INSERT ON items BEGIN
                    INSERT INTO search (rowid, text, names)
                    VALUES (new.rowid, coalesce(new.text, ''), coalesce((SELECT names FROM item_names WHERE item_id = new.id), ''));
                END;

                CREATE TRIGGER search_text_changed AFTER UPDATE OF text ON items WHEN old.text IS NOT new.text BEGIN
                    UPDATE search SET text = coalesce(new.text, '') WHERE rowid = new.rowid;
                END;

                CREATE TRIGGER search_item_removed AFTER DELETE ON items BEGIN
                    DELETE FROM search WHERE rowid = old.rowid;
                END;

                CREATE TRIGGER search_file_added AFTER INSERT ON attachments BEGIN
                    UPDATE search SET names = coalesce((SELECT names FROM item_names WHERE item_id = new.item_id), '')
                    WHERE rowid = (SELECT rowid FROM items WHERE id = new.item_id);
                END;

                CREATE TRIGGER search_file_removed AFTER DELETE ON attachments BEGIN
                    UPDATE search SET names = coalesce((SELECT names FROM item_names WHERE item_id = old.item_id), '')
                    WHERE rowid = (SELECT rowid FROM items WHERE id = old.item_id);
                END;

                CREATE TRIGGER search_file_changed AFTER UPDATE OF filename, item_id ON attachments
                WHEN old.filename IS NOT new.filename OR old.item_id IS NOT new.item_id BEGIN
                    UPDATE search SET names = coalesce((SELECT names FROM item_names WHERE item_id = old.item_id), '')
                    WHERE rowid = (SELECT rowid FROM items WHERE id = old.item_id);
                    UPDATE search SET names = coalesce((SELECT names FROM item_names WHERE item_id = new.item_id), '')
                    WHERE rowid = (SELECT rowid FROM items WHERE id = new.item_id);
                END;

                INSERT INTO search (rowid, text, names)
                SELECT rowid, coalesce(text, ''), coalesce((SELECT names FROM item_names WHERE item_id = items.id), '') FROM items;
                """)
        }
        migrator.registerMigration("v8") { db in
            try db.execute(sql: """
                CREATE TABLE drafts (
                    place TEXT PRIMARY KEY CHECK (place IN ('home', 'inbox', 'tunnel') OR place LIKE 'topic:_%'),
                    text TEXT NOT NULL CHECK (trim(text) <> ''),
                    home_topic_id TEXT CHECK (home_topic_id IS NULL OR place = 'home')
                ) STRICT;
                """)
        }
        return migrator
    }
}
