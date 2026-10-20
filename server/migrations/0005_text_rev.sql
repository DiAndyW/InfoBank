-- +goose Up
ALTER TABLE items ADD COLUMN text_rev bigint NOT NULL DEFAULT 0;

-- +goose Down
ALTER TABLE items DROP COLUMN text_rev;
