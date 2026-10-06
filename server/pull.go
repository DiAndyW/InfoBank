package server

import (
	"context"
	"database/sql"
	"log"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
)

type itemOut struct {
	ID          uuid.UUID    `json:"id"`
	TopicID     *uuid.UUID   `json:"topic_id"`
	Text        *string      `json:"text"`
	CaptureTime time.Time    `json:"capture_time"`
	DeletedAt   *time.Time   `json:"deleted_at"`
	Attachments []attachment `json:"attachments"`
	seq         int64
}

type topicOut struct {
	ID         uuid.UUID  `json:"id"`
	Name       string     `json:"name"`
	ArchivedAt *time.Time `json:"archived_at"`
	DeletedAt  *time.Time `json:"deleted_at"`
	seq        int64
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
	tx, err := a.db.BeginTx(ctx, &sql.TxOptions{Isolation: sql.LevelRepeatableRead, ReadOnly: true})
	if err != nil {
		return nil, err
	}
	defer tx.Rollback()

	rows, err := tx.QueryContext(ctx, `
		SELECT id, topic_id, text, capture_time, deleted_at, seq
		FROM items WHERE seq > $1 ORDER BY seq LIMIT $2`, cursor, pullPageSize+1)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []itemOut{}
	for rows.Next() {
		var it itemOut
		if err := rows.Scan(&it.ID, &it.TopicID, &it.Text, &it.CaptureTime, &it.DeletedAt, &it.seq); err != nil {
			return nil, err
		}
		it.CaptureTime, it.DeletedAt = it.CaptureTime.UTC(), utc(it.DeletedAt)
		items = append(items, it)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	rows, err = tx.QueryContext(ctx, `
		SELECT id, name, archived_at, deleted_at, seq
		FROM topics WHERE seq > $1 ORDER BY seq LIMIT $2`, cursor, pullPageSize+1)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	topics := []topicOut{}
	for rows.Next() {
		var tp topicOut
		if err := rows.Scan(&tp.ID, &tp.Name, &tp.ArchivedAt, &tp.DeletedAt, &tp.seq); err != nil {
			return nil, err
		}
		tp.ArchivedAt, tp.DeletedAt = utc(tp.ArchivedAt), utc(tp.DeletedAt)
		topics = append(topics, tp)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}

	// Keep the pullPageSize lowest seqs across both lists; the cursor is the last one kept.
	var i, j int
	for i+j < pullPageSize && (i < len(items) || j < len(topics)) {
		if j == len(topics) || (i < len(items) && items[i].seq < topics[j].seq) {
			cursor = items[i].seq
			i++
		} else {
			cursor = topics[j].seq
			j++
		}
	}
	hasMore := i < len(items) || j < len(topics)
	items, topics = items[:i], topics[:j]

	byID := map[uuid.UUID]*itemOut{}
	ids := []string{}
	for i := range items {
		items[i].Attachments = []attachment{}
		byID[items[i].ID] = &items[i]
		ids = append(ids, items[i].ID.String())
	}
	rows, err = tx.QueryContext(ctx, `
		SELECT item_id, id, filename, mime_type, size_bytes FROM attachments
		WHERE item_id = ANY($1::uuid[]) AND deleted_at IS NULL ORDER BY created_at, id`, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var itemID uuid.UUID
		var att attachment
		if err := rows.Scan(&itemID, &att.ID, &att.Filename, &att.MimeType, &att.SizeBytes); err != nil {
			return nil, err
		}
		byID[itemID].Attachments = append(byID[itemID].Attachments, att)
	}
	if err := rows.Err(); err != nil {
		return nil, err
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
