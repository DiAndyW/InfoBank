package server

import (
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func (a attachment) valid() bool {
	return a.ID != uuid.Nil &&
		storable(a.Filename, maxAttachmentFieldBytes) && storable(a.MimeType, maxAttachmentFieldBytes) &&
		a.SizeBytes >= 0 && a.SizeBytes <= maxAttachmentBytes
}

func (b *batch) attachmentExists(id uuid.UUID) (bool, error) {
	var exists bool
	err := b.tx.QueryRow(b.ctx, `SELECT EXISTS (SELECT 1 FROM attachments WHERE id = $1)`, id).Scan(&exists)
	return exists, err
}

// insertAttachment records metadata only; the Server names the file after the id so no Device picks a path.
func (b *batch) insertAttachment(itemID uuid.UUID, a attachment) error {
	_, err := b.tx.Exec(b.ctx, `
		INSERT INTO attachments (id, item_id, file_key, filename, mime_type, size_bytes)
		VALUES ($1, $2, $3, $4, $5, $6)`,
		a.ID, itemID, a.ID.String(), a.Filename, a.MimeType, a.SizeBytes)
	return err
}

// removeAttachment reports false if the Item has no Attachment with id. Removing twice is harmless.
func (b *batch) removeAttachment(itemID, id uuid.UUID, at time.Time) (bool, error) {
	var removed bool
	err := b.tx.QueryRow(b.ctx, `
		UPDATE attachments SET deleted_at = coalesce(deleted_at, $3)
		WHERE id = $1 AND item_id = $2 RETURNING true`, id, itemID, at).Scan(&removed)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return removed, err
}

func (b *batch) hasLiveAttachments(itemID uuid.UUID) (bool, error) {
	var attached bool
	err := b.tx.QueryRow(b.ctx, `
		SELECT EXISTS (SELECT 1 FROM attachments WHERE item_id = $1 AND deleted_at IS NULL)`, itemID).Scan(&attached)
	return attached, err
}
