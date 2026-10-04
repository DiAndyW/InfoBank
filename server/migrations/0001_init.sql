-- +goose Up
CREATE TABLE topics (
    id          uuid PRIMARY KEY,
    name        text NOT NULL CHECK (btrim(name) <> ''),
    archived_at timestamptz, -- NULL = not archived
    deleted_at  timestamptz, -- NULL = live
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- A deleted Topic's name is free to reuse.
CREATE UNIQUE INDEX topics_name_unique ON topics (lower(name)) WHERE deleted_at IS NULL;

CREATE TABLE items (
    id                     uuid PRIMARY KEY,
    topic_id               uuid REFERENCES topics (id), -- NULL = Inbox
    text                   text CHECK (text <> ''),     -- no text is NULL, never ''
    capture_time           timestamptz NOT NULL,
    deleted_at             timestamptz,                 -- set = in Trash
    text_updated_at        timestamptz NOT NULL,
    topic_updated_at       timestamptz NOT NULL,
    attachments_updated_at timestamptz NOT NULL,
    created_at             timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX items_topic_capture_time ON items (topic_id, capture_time);

CREATE TABLE attachments (
    id         uuid PRIMARY KEY,
    item_id    uuid NOT NULL REFERENCES items (id) ON DELETE CASCADE,
    file_key   text NOT NULL UNIQUE, -- opaque storage key, not a filesystem path
    filename   text NOT NULL,
    mime_type  text NOT NULL,
    size_bytes bigint NOT NULL CHECK (size_bytes >= 0),
    deleted_at timestamptz, -- NULL = live
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX attachments_item ON attachments (item_id);

-- +goose Down
DROP TABLE attachments;
DROP TABLE items;
DROP TABLE topics;
