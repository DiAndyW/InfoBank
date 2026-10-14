-- +goose Up
-- Purged Items, so Devices pulling later drop them too. Kept forever: a Device may sync after any gap.
CREATE TABLE tombstones (
    item_id uuid PRIMARY KEY,
    seq     bigint NOT NULL UNIQUE
);

-- Server time, set by the push, so pruning follows the same clock as the rest of the purge.
ALTER TABLE applied_ops ALTER COLUMN created_at DROP DEFAULT;

-- +goose Down
ALTER TABLE applied_ops ALTER COLUMN created_at SET DEFAULT now();
DROP TABLE tombstones;
