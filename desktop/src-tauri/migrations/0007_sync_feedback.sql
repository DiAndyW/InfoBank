ALTER TABLE items ADD COLUMN text_rev INTEGER NOT NULL DEFAULT 0;
ALTER TABLE items ADD COLUMN sync_error TEXT;
CREATE TABLE conflicts (
    item_id TEXT PRIMARY KEY REFERENCES items (id) ON DELETE CASCADE,
    text    TEXT,
    mine    INTEGER NOT NULL
);
UPDATE device SET pull_cursor = 0;
