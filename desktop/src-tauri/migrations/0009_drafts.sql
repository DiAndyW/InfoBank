CREATE TABLE drafts (
    place         TEXT PRIMARY KEY CHECK (place IN ('home', 'inbox', 'tunnel') OR (place LIKE 'topic:_%')),
    text          TEXT NOT NULL CHECK (trim(text) <> ''),
    home_topic_id TEXT CHECK (home_topic_id IS NULL OR place = 'home') -- NULL = Inbox
) STRICT;
