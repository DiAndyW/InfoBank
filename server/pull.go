package server

import (
	"context"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type itemOut struct {
	ID          uuid.UUID       `json:"id"`
	TopicID     *uuid.UUID      `json:"topic_id" db:"topic_id"`
	Text        *string         `json:"text"`
	CaptureTime time.Time       `json:"capture_time" db:"capture_time"`
	DeletedAt   *time.Time      `json:"deleted_at" db:"deleted_at"`
	Attachments []attachmentOut `json:"attachments" db:"-"`
	Seq         int64           `json:"-"`
}

// attachmentOut adds what only the Server knows, kept off attachment so a push can't set it.
type attachmentOut struct {
	attachment
	Uploaded     bool `json:"uploaded"`
	HasThumbnail bool `json:"has_thumbnail" db:"has_thumbnail"`
}

type topicOut struct {
	ID         uuid.UUID  `json:"id"`
	Name       string     `json:"name"`
	ArchivedAt *time.Time `json:"archived_at" db:"archived_at"`
	DeletedAt  *time.Time `json:"deleted_at" db:"deleted_at"`
	Seq        int64      `json:"-"`
}

func (a *syncAPI) pull(w http.ResponseWriter, r *http.Request) {
	cursor, err := strconv.ParseInt(r.URL.Query().Get("cursor"), 10, 64)
	if err != nil || cursor < 0 {
		http.Error(w, "cursor must be a non-negative integer", http.StatusBadRequest)
		return
	}
	page, err := a.pullPage(r.Context(), cursor)
	if err != nil {
		log.Printf("pull: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	writeJSON(w, page)
}

func (a *syncAPI) pullPage(ctx context.Context, cursor int64) (map[string]any, error) {
	// One snapshot for every query, so a push committing mid-pull can't make the cursor jump past a change.
	tx, err := a.db.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)

	// CollectRows returns Query's error, so it isn't checked separately.
	rows, _ := tx.Query(ctx, `
		SELECT id, topic_id, text, capture_time, deleted_at, seq
		FROM items WHERE seq > $1 ORDER BY seq LIMIT $2`, cursor, pullPageSize+1)
	items, err := pgx.CollectRows(rows, pgx.RowToStructByName[itemOut])
	if err != nil {
		return nil, err
	}
	rows, _ = tx.Query(ctx, `
		SELECT id, name, archived_at, deleted_at, seq
		FROM topics WHERE seq > $1 ORDER BY seq LIMIT $2`, cursor, pullPageSize+1)
	topics, err := pgx.CollectRows(rows, pgx.RowToStructByName[topicOut])
	if err != nil {
		return nil, err
	}

	// Keep the pullPageSize lowest seqs across both lists; the cursor is the last one kept.
	var i, j int
	for i+j < pullPageSize && (i < len(items) || j < len(topics)) {
		if j == len(topics) || (i < len(items) && items[i].Seq < topics[j].Seq) {
			cursor = items[i].Seq
			i++
		} else {
			cursor = topics[j].Seq
			j++
		}
	}
	hasMore := i < len(items) || j < len(topics)
	items, topics = items[:i], topics[:j]

	byID := map[uuid.UUID]*itemOut{}
	ids := []uuid.UUID{}
	for i := range items {
		it := &items[i]
		it.CaptureTime, it.DeletedAt, it.Attachments = it.CaptureTime.UTC(), utc(it.DeletedAt), []attachmentOut{}
		byID[it.ID] = it
		ids = append(ids, it.ID)
	}
	for i := range topics {
		topics[i].ArchivedAt, topics[i].DeletedAt = utc(topics[i].ArchivedAt), utc(topics[i].DeletedAt)
	}

	type itemAttachment struct {
		ItemID uuid.UUID `db:"item_id"`
		attachmentOut
	}
	rows, _ = tx.Query(ctx, `
		SELECT item_id, id, filename, mime_type, size_bytes,
			uploaded_at IS NOT NULL AS uploaded, thumbnail_key IS NOT NULL AS has_thumbnail
		FROM attachments
		WHERE item_id = ANY($1) AND deleted_at IS NULL ORDER BY created_at, id`, ids)
	attachments, err := pgx.CollectRows(rows, pgx.RowToStructByName[itemAttachment])
	if err != nil {
		return nil, err
	}
	for _, ia := range attachments {
		byID[ia.ItemID].Attachments = append(byID[ia.ItemID].Attachments, ia.attachmentOut)
	}
	return map[string]any{"items": items, "topics": topics, "cursor": cursor, "has_more": hasMore}, nil
}

// utc puts an optional time in UTC; the database driver returns times in the machine's local zone.
func utc(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	u := t.UTC()
	return &u
}
