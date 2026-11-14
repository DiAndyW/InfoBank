ALTER TABLE topics ADD COLUMN activity_at INTEGER NOT NULL DEFAULT 0;
UPDATE topics SET activity_at = COALESCE(
    (SELECT max(capture_time) FROM items WHERE topic_id = topics.id), 0
);
