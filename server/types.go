package server

import (
	"bytes"
	"context"
	"database/sql"
	"time"

	"github.com/google/uuid"
)

// Types shared by more than one file. A type used by a single file lives in that file.

type syncAPI struct {
	db  *sql.DB
	now func() time.Time
}

// batch applies one push's ops inside its transaction.
type batch struct {
	ctx    context.Context
	tx     *sql.Tx
	device uuid.UUID
	now    time.Time // also an Item's deleted_at, so a late-syncing Trash still gets its full 30 days
}

type pushOp struct {
	ID      uuid.UUID  `json:"id"`
	Type    string     `json:"type"`
	At      time.Time  `json:"at"`
	ItemID  uuid.UUID  `json:"item_id"`
	TopicID *uuid.UUID `json:"topic_id"`
	Text    *string    `json:"text"`

	Name  string      `json:"name"`
	Trash []uuid.UUID `json:"trash"` // DeleteTopic: the Items to trash; the rest go to the Inbox

	Attachment   *attachment  `json:"attachment"`  // AddAttachment
	Attachments  []attachment `json:"attachments"` // CaptureItem
	AttachmentID uuid.UUID    `json:"attachment_id"`
}

type opResult struct {
	OpID   uuid.UUID `json:"op_id"`
	Status string    `json:"status"` // accepted, changed or rejected
	Reason string    `json:"reason,omitempty"`
}

func accepted() opResult              { return opResult{Status: "accepted"} }
func rejected(reason string) opResult { return opResult{Status: "rejected", Reason: reason} }
func changed(reason string) opResult  { return opResult{Status: "changed", Reason: reason} }

// stamp is when and by which Device a last-write-wins field was set.
type stamp struct {
	at time.Time
	by uuid.UUID
}

// beats: later wins; a tie goes to the lower Device id, or to the newer op from the same Device.
func (s stamp) beats(cur stamp) bool {
	if !s.at.Equal(cur.at) {
		return s.at.After(cur.at)
	}
	return bytes.Compare(s.by[:], cur.by[:]) <= 0
}

type item struct {
	id         uuid.UUID
	topicID    *uuid.UUID
	text       *string
	deletedAt  *time.Time
	textStamp  stamp
	topicStamp stamp
	trashStamp stamp
}

type attachment struct {
	ID        uuid.UUID `json:"id"`
	Filename  string    `json:"filename"`
	MimeType  string    `json:"mime_type"`
	SizeBytes int64     `json:"size_bytes"`
}
