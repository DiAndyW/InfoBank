ALTER TABLE items ADD COLUMN in_tunnel INTEGER NOT NULL DEFAULT 0
    CHECK (in_tunnel IN (0, 1) AND NOT (in_tunnel = 1 AND topic_id IS NOT NULL));

CREATE TABLE settings (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    trash_after_copy INTEGER CHECK (trash_after_copy IN (0, 1))
) STRICT;
INSERT INTO settings (id) VALUES (1);
