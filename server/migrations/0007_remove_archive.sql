-- +goose Up
UPDATE topics SET seq = nextval('sync_seq') WHERE archived_at IS NOT NULL;

ALTER TABLE topics
    DROP COLUMN archived_at,
    DROP COLUMN archive_updated_at,
    DROP COLUMN archive_updated_by;

-- +goose Down
ALTER TABLE topics
    ADD COLUMN archived_at timestamptz,
    ADD COLUMN archive_updated_at timestamptz,
    ADD COLUMN archive_updated_by uuid;

UPDATE topics
SET archive_updated_at = name_updated_at,
    archive_updated_by = name_updated_by;

ALTER TABLE topics
    ALTER COLUMN archive_updated_at SET NOT NULL,
    ALTER COLUMN archive_updated_by SET NOT NULL;
