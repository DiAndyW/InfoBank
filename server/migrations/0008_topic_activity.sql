-- +goose Up
ALTER TABLE topics ADD COLUMN activity_at timestamptz;
UPDATE topics
SET activity_at = GREATEST(created_at, (SELECT max(capture_time) FROM items WHERE topic_id = topics.id)),
    seq = nextval('sync_seq');
ALTER TABLE topics ALTER COLUMN activity_at SET NOT NULL;

-- +goose Down
ALTER TABLE topics DROP COLUMN activity_at;
