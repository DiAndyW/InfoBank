package server

import (
	"context"
	"log"
	"net/http"
	"slices"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

type itemOut struct {
	ID          uuid.UUID       `json:"id"`
	TopicID     *uuid.UUID      `json:"topic_id" db:"topic_id"`
	Tunnel      bool            `json:"tunnel" db:"in_tunnel"`
	Text        *string         `json:"text"`
	TextRev     int64           `json:"text_rev" db:"text_rev"`
	CaptureTime time.Time       `json:"capture_time" db:"capture_time"`
	DeletedAt   *time.Time      `json:"deleted_at" db:"deleted_at"`
	PurgeAt     *time.Time      `json:"purge_at" db:"-"`
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
	DeletedAt  *time.Time `json:"deleted_at" db:"deleted_at"`
	ActivityAt time.Time  `json:"activity_at" db:"activity_at"`
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
		SELECT id, topic_id, in_tunnel, text, text_rev, capture_time, deleted_at, seq
		FROM items WHERE seq > $1 ORDER BY seq LIMIT $2`, cursor, pullPageSize+1)
	items, err := pgx.CollectRows(rows, pgx.RowToStructByName[itemOut])
	if err != nil {
		return nil, err
	}
	rows, _ = tx.Query(ctx, `
		SELECT id, name, deleted_at, activity_at, seq
		FROM topics WHERE seq > $1 ORDER BY seq LIMIT $2`, cursor, pullPageSize+1)
	topics, err := pgx.CollectRows(rows, pgx.RowToStructByName[topicOut])
	if err != nil {
		return nil, err
	}

	type tombstone struct {
		ItemID uuid.UUID `db:"item_id"`
		Seq    int64
	}
	rows, _ = tx.Query(ctx, `
		SELECT item_id, seq FROM tombstones WHERE seq > $1 ORDER BY seq LIMIT $2`, cursor, pullPageSize+1)
	tombstones, err := pgx.CollectRows(rows, pgx.RowToStructByName[tombstone])
	if err != nil {
		return nil, err
	}

	// Keep the pullPageSize lowest seqs across the lists; the cursor is the last one kept.
	var seqs []int64
	for _, it := range items {
		seqs = append(seqs, it.Seq)
	}
	for _, tp := range topics {
		seqs = append(seqs, tp.Seq)
	}
	for _, ts := range tombstones {
		seqs = append(seqs, ts.Seq)
	}
	slices.Sort(seqs)
	hasMore := len(seqs) > pullPageSize
	if hasMore {
		seqs = seqs[:pullPageSize]
	}
	if len(seqs) > 0 {
		cursor = seqs[len(seqs)-1]
	}
	items = slices.DeleteFunc(items, func(it itemOut) bool { return it.Seq > cursor })
	topics = slices.DeleteFunc(topics, func(tp topicOut) bool { return tp.Seq > cursor })
	purged := []uuid.UUID{}
	for _, ts := range tombstones {
		if ts.Seq <= cursor {
			purged = append(purged, ts.ItemID)
		}
	}

	byID := map[uuid.UUID]*itemOut{}
	ids := []uuid.UUID{}
	for i := range items {
		it := &items[i]
		it.CaptureTime, it.DeletedAt, it.Attachments = it.CaptureTime.UTC(), utc(it.DeletedAt), []attachmentOut{}
		if it.DeletedAt != nil {
			purgeAt := it.DeletedAt.Add(trashRetention)
			it.PurgeAt = &purgeAt
		}
		byID[it.ID] = it
		ids = append(ids, it.ID)
	}
	for i := range topics {
		topics[i].DeletedAt = utc(topics[i].DeletedAt)
		topics[i].ActivityAt = topics[i].ActivityAt.UTC()
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
	var trashAfterCopy *bool
	if err := tx.QueryRow(ctx, `SELECT trash_after_copy FROM settings`).Scan(&trashAfterCopy); err != nil {
		return nil, err
	}
	settings := map[string]*bool{"trash_after_copy": trashAfterCopy}
	return map[string]any{"items": items, "topics": topics, "tombstones": purged, "cursor": cursor, "has_more": hasMore, "settings": settings}, nil
}

// utc puts an optional time in UTC; the database driver returns times in the machine's local zone.
func utc(t *time.Time) *time.Time {
	if t == nil {
		return nil
	}
	u := t.UTC()
	return &u
}
