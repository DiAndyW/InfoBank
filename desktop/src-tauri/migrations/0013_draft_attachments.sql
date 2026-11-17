ALTER TABLE drafts RENAME TO old_drafts;
CREATE TABLE drafts (
    place TEXT NOT NULL PRIMARY KEY CHECK (place IN ('home', 'inbox', 'tunnel') OR place LIKE 'topic:_%'),
    text TEXT NOT NULL,
    home_topic_id TEXT CHECK (home_topic_id IS NULL OR place = 'home')
) STRICT;
INSERT INTO drafts SELECT * FROM old_drafts;
DROP TABLE old_drafts;
CREATE TABLE draft_attachments (
    attachment_id TEXT NOT NULL PRIMARY KEY,
    place TEXT NOT NULL REFERENCES drafts(place) ON DELETE CASCADE,
    position INTEGER NOT NULL CHECK (position >= 0),
    filename TEXT NOT NULL,
    mime_type TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    UNIQUE(place, position)
) STRICT;
