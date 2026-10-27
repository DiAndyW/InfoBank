-- +goose Up
ALTER TABLE items ADD COLUMN in_tunnel boolean NOT NULL DEFAULT false,
    ADD CONSTRAINT items_tunnel_no_topic CHECK (NOT in_tunnel OR topic_id IS NULL);

CREATE TABLE settings (
    id                          boolean PRIMARY KEY DEFAULT true CHECK (id),
    trash_after_copy            boolean,            -- NULL = not asked yet
    trash_after_copy_updated_at timestamptz NOT NULL,
    trash_after_copy_updated_by uuid NOT NULL
);
INSERT INTO settings (trash_after_copy_updated_at, trash_after_copy_updated_by)
VALUES ('1970-01-01T00:00:00Z', '00000000-0000-0000-0000-000000000000');

-- +goose Down
DROP TABLE settings;
ALTER TABLE items DROP CONSTRAINT items_tunnel_no_topic, DROP COLUMN in_tunnel;
