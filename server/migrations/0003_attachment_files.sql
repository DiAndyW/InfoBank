-- +goose Up
-- Metadata syncs before the file is uploaded, so both start out absent.
ALTER TABLE attachments
    ADD COLUMN uploaded_at   timestamptz, -- NULL = file not uploaded yet
    ADD COLUMN thumbnail_key text UNIQUE; -- NULL = no thumbnail; opaque like file_key

-- +goose Down
ALTER TABLE attachments
    DROP COLUMN thumbnail_key,
    DROP COLUMN uploaded_at;
