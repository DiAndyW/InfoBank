package server

import (
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type topic struct {
	id           uuid.UUID
	name         string
	archivedAt   *time.Time
	deletedAt    *time.Time
	nameStamp    stamp
	archiveStamp stamp
}

func (b *batch) createTopic(o pushOp, s stamp) (opResult, error) {
	name := strings.TrimSpace(o.Name)
	if o.TopicID == nil || *o.TopicID == uuid.Nil || !storable(name, maxTopicNameBytes) {
		return rejected("invalid"), nil
	}
	if tp, err := b.loadTopic(*o.TopicID); tp != nil || err != nil {
		return rejected("exists"), err
	}
	free, err := b.freeName(name, *o.TopicID)
	if err != nil {
		return opResult{}, err
	}
	_, err = b.tx.Exec(b.ctx, `
		INSERT INTO topics (id, name, name_updated_at, name_updated_by, archive_updated_at, archive_updated_by, seq)
		VALUES ($1, $2, $3, $4, $3, $4, nextval('sync_seq'))`,
		*o.TopicID, free, s.at, s.by)
	if free != name {
		return changed("renamed"), err
	}
	return accepted(), err
}

func (b *batch) changeTopic(o pushOp, s stamp) (opResult, error) {
	if o.TopicID == nil {
		return rejected("invalid"), nil
	}
	tp, err := b.loadTopic(*o.TopicID)
	if err != nil || tp == nil {
		return rejected("not_found"), err
	}
	if tp.deletedAt != nil {
		return rejected("topic_deleted"), nil
	}

	res := accepted()
	switch o.Type {
	case "RenameTopic":
		name := strings.TrimSpace(o.Name)
		if !storable(name, maxTopicNameBytes) {
			return rejected("invalid"), nil
		}
		if !s.beats(tp.nameStamp) {
			return rejected("superseded"), nil
		}
		free, err := b.freeName(name, tp.id)
		if err != nil {
			return opResult{}, err
		}
		if free != name {
			res = changed("renamed")
		}
		tp.name, tp.nameStamp = free, s
	case "ArchiveTopic", "UnarchiveTopic":
		if !s.beats(tp.archiveStamp) {
			return rejected("superseded"), nil
		}
		tp.archivedAt, tp.archiveStamp = nil, s
		if o.Type == "ArchiveTopic" {
			tp.archivedAt = &s.at
		}
	case "DeleteTopic":
		tp.deletedAt = &s.at
		if err := b.emptyDeletedTopic(tp.id, o.Trash, s); err != nil {
			return opResult{}, err
		}
	}
	return res, b.saveTopic(tp)
}

// emptyDeletedTopic moves every Item out to the Inbox, so no Item ever points at a deleted Topic.
func (b *batch) emptyDeletedTopic(topicID uuid.UUID, trash []uuid.UUID, s stamp) error {
	toTrash := map[uuid.UUID]bool{}
	for _, id := range trash {
		toTrash[id] = true
	}
	rows, _ := b.tx.Query(b.ctx, `SELECT id FROM items WHERE topic_id = $1`, topicID) // CollectRows returns Query's error
	ids, err := pgx.CollectRows(rows, pgx.RowTo[uuid.UUID])
	if err != nil {
		return err
	}

	for _, id := range ids {
		it, err := b.loadItem(id)
		if err != nil {
			return err
		}
		// The Topic stamp stays, so an older move to another Topic arriving later still wins.
		it.topicID = nil
		if toTrash[id] && s.beats(it.trashStamp) {
			it.deletedAt, it.trashStamp = &b.now, s
		}
		if err := b.saveItem(it); err != nil {
			return err
		}
	}
	return nil
}

// freeName returns name, or "name (n)" with the smallest n that no other live Topic uses, ignoring case.
func (b *batch) freeName(name string, self uuid.UUID) (string, error) {
	for n := 0; ; n++ {
		candidate := name
		if n > 0 {
			candidate = fmt.Sprintf("%s (%d)", name, n)
		}
		var taken bool
		err := b.tx.QueryRow(b.ctx, `
			SELECT EXISTS (SELECT 1 FROM topics WHERE lower(name) = lower($1) AND deleted_at IS NULL AND id <> $2)`,
			candidate, self).Scan(&taken)
		if err != nil || !taken {
			return candidate, err
		}
	}
}

// topicOpen reports whether the Topic with id exists and can take Items: not archived or deleted.
func (b *batch) topicOpen(id uuid.UUID) (bool, error) {
	var open bool
	err := b.tx.QueryRow(b.ctx, `
		SELECT EXISTS (SELECT 1 FROM topics WHERE id = $1 AND archived_at IS NULL AND deleted_at IS NULL)`, id).Scan(&open)
	return open, err
}

// loadTopic returns nil if there is no Topic with id.
func (b *batch) loadTopic(id uuid.UUID) (*topic, error) {
	tp := topic{id: id}
	err := b.tx.QueryRow(b.ctx, `
		SELECT name, archived_at, deleted_at, name_updated_at, name_updated_by, archive_updated_at, archive_updated_by
		FROM topics WHERE id = $1`, id).Scan(
		&tp.name, &tp.archivedAt, &tp.deletedAt, &tp.nameStamp.at, &tp.nameStamp.by, &tp.archiveStamp.at, &tp.archiveStamp.by)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	return &tp, err
}

func (b *batch) saveTopic(tp *topic) error {
	_, err := b.tx.Exec(b.ctx, `
		UPDATE topics SET name = $2, archived_at = $3, deleted_at = $4, name_updated_at = $5, name_updated_by = $6,
			archive_updated_at = $7, archive_updated_by = $8, seq = nextval('sync_seq')
		WHERE id = $1`,
		tp.id, tp.name, tp.archivedAt, tp.deletedAt, tp.nameStamp.at, tp.nameStamp.by, tp.archiveStamp.at, tp.archiveStamp.by)
	return err
}
