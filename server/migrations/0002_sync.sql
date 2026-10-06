-- +goose Up
-- Every change gets the next value; pull cursors are positions in it.
CREATE SEQUENCE sync_seq;

-- Each last-write-wins field keeps the Device timestamp and Device id that last set it.
ALTER TABLE items
    DROP COLUMN attachments_updated_at,
    ADD COLUMN text_updated_by  uuid NOT NULL,
    ADD COLUMN topic_updated_by uuid NOT NULL,
    ADD COLUMN trash_updated_at timestamptz NOT NULL,
    ADD COLUMN trash_updated_by uuid NOT NULL,
    ADD COLUMN seq              bigint NOT NULL UNIQUE;

ALTER TABLE topics
    DROP COLUMN updated_at,
    ADD COLUMN name_updated_at    timestamptz NOT NULL,
    ADD COLUMN name_updated_by    uuid NOT NULL,
    ADD COLUMN archive_updated_at timestamptz NOT NULL,
    ADD COLUMN archive_updated_by uuid NOT NULL,
    ADD COLUMN seq                bigint NOT NULL UNIQUE;

-- Results of pushed operations, so a replayed operation returns its first result and changes nothing.
CREATE TABLE applied_ops (
    op_id      uuid PRIMARY KEY,
    result     jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- +goose Down
DROP TABLE applied_ops;

ALTER TABLE topics
    DROP COLUMN seq,
    DROP COLUMN archive_updated_by,
    DROP COLUMN archive_updated_at,
    DROP COLUMN name_updated_by,
    DROP COLUMN name_updated_at,
    ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

ALTER TABLE items
    DROP COLUMN seq,
    DROP COLUMN trash_updated_by,
    DROP COLUMN trash_updated_at,
    DROP COLUMN topic_updated_by,
    DROP COLUMN text_updated_by,
    ADD COLUMN attachments_updated_at timestamptz NOT NULL DEFAULT now();

DROP SEQUENCE sync_seq;
