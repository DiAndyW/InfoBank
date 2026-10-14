-- Mirrors of the Server: pull overwrites these, the UI reads them. Times are UTC microseconds since the epoch.
CREATE TABLE topics (
    id          TEXT PRIMARY KEY,
    name        TEXT NOT NULL CHECK (trim(name) <> ''),
    archived_at INTEGER, -- NULL = not archived
    deleted_at  INTEGER  -- NULL = live
) STRICT;

CREATE TABLE items (
    id           TEXT PRIMARY KEY,
    topic_id     TEXT,    -- NULL = Inbox. No FK: a pull page can hold an Item before the Topic it moved into.
    text         TEXT CHECK (text <> ''),
    capture_time INTEGER NOT NULL,
    deleted_at   INTEGER, -- set = in Trash
    purge_at     INTEGER  -- when the Server purges it from Trash
) STRICT;
CREATE INDEX items_topic_capture_time ON items (topic_id, capture_time);

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

-- Push ops not yet accepted by the Server, sent in seq order. Each op carries its own id, so a retry is safe.
CREATE TABLE outbox (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    op  TEXT NOT NULL
) STRICT;

CREATE TABLE device (
    id          INTEGER PRIMARY KEY CHECK (id = 1),
    device_id   TEXT NOT NULL,
    server_url  TEXT, -- NULL = not set up yet
    pull_cursor INTEGER NOT NULL DEFAULT 0
) STRICT;

-- An Attachment file not yet uploaded stays pinned: eviction skips rows whose attachment has uploaded = 0.
CREATE TABLE cached_files (
    attachment_id TEXT NOT NULL,
    kind          TEXT NOT NULL CHECK (kind IN ('file', 'thumbnail')),
    path          TEXT NOT NULL,
    size_bytes    INTEGER NOT NULL CHECK (size_bytes >= 0),
    last_used_at  INTEGER NOT NULL,
    PRIMARY KEY (attachment_id, kind)
) STRICT;
