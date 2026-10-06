package server

import (
	"errors"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

func validText(text *string) bool {
	return text == nil || storable(*text, maxItemTextBytes)
}

func (b *batch) captureItem(o pushOp, s stamp) (opResult, error) {
	if o.ItemID == uuid.Nil || !validText(o.Text) || (o.Text == nil && len(o.Attachments) == 0) {
		return rejected("invalid"), nil
	}
	seen := map[uuid.UUID]bool{}
	for _, a := range o.Attachments {
		if !a.valid() || seen[a.ID] {
			return rejected("invalid"), nil
		}
		seen[a.ID] = true
		if exists, err := b.attachmentExists(a.ID); exists || err != nil {
			return rejected("exists"), err
		}
	}

	// A Capture is never lost: if its Topic can't take Items any more, it goes to the Inbox.
	result, topicID := accepted(), o.TopicID
	if topicID != nil {
		open, err := b.topicOpen(*topicID)
		if err != nil {
			return opResult{}, err
		}
		if !open {
			result, topicID = changed("sent_to_inbox"), nil
		}
	}

	res, err := b.tx.Exec(b.ctx, `
		INSERT INTO items (id, topic_id, text, capture_time,
			text_updated_at, text_updated_by, topic_updated_at, topic_updated_by,
			trash_updated_at, trash_updated_by, seq)
		VALUES ($1, $2, $3, $4, $4, $5, $4, $5, $4, $5, nextval('sync_seq'))
		ON CONFLICT (id) DO NOTHING`,
		o.ItemID, topicID, o.Text, s.at, s.by)
	if err != nil {
		return opResult{}, err
	}
	if res.RowsAffected() == 0 {
		return rejected("exists"), nil
	}
	for _, a := range o.Attachments {
		if err := b.insertAttachment(o.ItemID, a); err != nil {
			return opResult{}, err
		}
	}
	return result, nil
}

// changeItem applies every Item op except Capture.
func (b *batch) changeItem(o pushOp, s stamp) (opResult, error) {
	if o.ItemID == uuid.Nil {
		return rejected("invalid"), nil
	}
	it, err := b.loadItem(o.ItemID)
	if err != nil || it == nil {
		return rejected("not_found"), err
	}
	edit := false
	switch o.Type {
	case "SetText":
		if !validText(o.Text) {
			return rejected("invalid"), nil
		}
		if !s.beats(it.textStamp) {
			return rejected("superseded"), nil
		}
		it.text, it.textStamp, edit = o.Text, s, true
	case "MoveItem":
		if o.TopicID != nil {
			open, err := b.topicOpen(*o.TopicID)
			if err != nil || !open {
				return rejected("topic_unavailable"), err
			}
		}
		if !s.beats(it.topicStamp) {
			return rejected("superseded"), nil
		}
		it.topicID, it.topicStamp, edit = o.TopicID, s, true
	case "AddAttachment":
		if o.Attachment == nil || !o.Attachment.valid() {
			return rejected("invalid"), nil
		}
		if exists, err := b.attachmentExists(o.Attachment.ID); exists || err != nil {
			return rejected("exists"), err
		}
		if err := b.insertAttachment(it.id, *o.Attachment); err != nil {
			return opResult{}, err
		}
		edit = true
	case "RemoveAttachment":
		// Removal isn't last-write-wins: ids are never reused, so a removed Attachment can't come back.
		removed, err := b.removeAttachment(it.id, o.AttachmentID, s.at)
		if err != nil || !removed {
			return rejected("not_found"), err
		}
	case "TrashItem", "RestoreItem":
		if !s.beats(it.trashStamp) {
			return rejected("superseded"), nil
		}
		it.deletedAt, it.trashStamp = nil, s
		if o.Type == "TrashItem" {
			it.deletedAt = &b.now
		}
	default:
		return rejected("invalid"), nil
	}

	// An edit counts as a restore at its timestamp, so one made after a Trash brings the Item back.
	if edit && s.beats(it.trashStamp) {
		it.deletedAt, it.trashStamp = nil, s
	}

	attached := false
	if it.text == nil {
		if attached, err = b.hasLiveAttachments(it.id); err != nil {
			return opResult{}, err
		}
	}
	if it.text == nil && !attached && it.deletedAt == nil {
		if o.Type == "RestoreItem" {
			return rejected("empty"), nil
		}
		it.deletedAt = &b.now
	}
	return accepted(), b.saveItem(it)
}

// loadItem returns nil if there is no Item with id.
func (b *batch) loadItem(id uuid.UUID) (*item, error) {
	it := item{id: id}
	err := b.tx.QueryRow(b.ctx, `
		SELECT topic_id, text, deleted_at, text_updated_at, text_updated_by,
			topic_updated_at, topic_updated_by, trash_updated_at, trash_updated_by
		FROM items WHERE id = $1`, id).Scan(
		&it.topicID, &it.text, &it.deletedAt, &it.textStamp.at, &it.textStamp.by,
		&it.topicStamp.at, &it.topicStamp.by, &it.trashStamp.at, &it.trashStamp.by)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &it, err
}

func (b *batch) saveItem(it *item) error {
	_, err := b.tx.Exec(b.ctx, `
		UPDATE items SET topic_id = $2, text = $3, deleted_at = $4,
			text_updated_at = $5, text_updated_by = $6, topic_updated_at = $7, topic_updated_by = $8,
			trash_updated_at = $9, trash_updated_by = $10, seq = nextval('sync_seq')
		WHERE id = $1`,
		it.id, it.topicID, it.text, it.deletedAt, it.textStamp.at, it.textStamp.by,
		it.topicStamp.at, it.topicStamp.by, it.trashStamp.at, it.trashStamp.by)
	return err
}
