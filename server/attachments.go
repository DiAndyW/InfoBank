package server

import (
	"bytes"
	"context"
	"errors"
	"log"
	"mime"
	"net/http"
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

// upload stores the file for an Attachment whose metadata was already pushed.
// 404 means push the metadata first; 410 means the Attachment was removed, so stop retrying.
func (a *syncAPI) upload(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	var fileKey string
	var sizeBytes int64
	var removed, uploaded bool
	err = a.db.QueryRow(r.Context(), `
		SELECT file_key, size_bytes, deleted_at IS NOT NULL, uploaded_at IS NOT NULL
		FROM attachments WHERE id = $1`, id).Scan(&fileKey, &sizeBytes, &removed, &uploaded)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		http.NotFound(w, r)
		return
	case err != nil:
		log.Printf("upload: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	case removed:
		w.WriteHeader(http.StatusGone)
		return
	case uploaded:
		w.WriteHeader(http.StatusNoContent)
		return
	}

	if err := a.files.Put(fileKey, r.Body, sizeBytes); err != nil {
		if errors.Is(err, errSizeMismatch) {
			http.Error(w, "body must be exactly size_bytes long", http.StatusBadRequest)
			return
		}
		log.Printf("upload: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	thumbnailKey, err := a.storeThumbnail(fileKey)
	if err != nil {
		log.Printf("upload: thumbnail: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	live, err := a.markUploaded(r.Context(), id, thumbnailKey)
	switch {
	case err != nil:
		log.Printf("upload: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
	case !live: // removed mid-upload; the stored file is left behind
		w.WriteHeader(http.StatusGone)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
}

// storeThumbnail returns nil if the file isn't an image that can be thumbnailed.
func (a *syncAPI) storeThumbnail(fileKey string) (*string, error) {
	f, err := a.files.Open(fileKey)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	thumb := thumbnailJPEG(f)
	if thumb == nil {
		return nil, nil
	}
	key := uuid.NewString()
	return &key, a.files.Put(key, bytes.NewReader(thumb), int64(len(thumb)))
}

// markUploaded reports false if the Attachment was removed. It bumps the Item's seq so Devices re-pull it.
func (a *syncAPI) markUploaded(ctx context.Context, id uuid.UUID, thumbnailKey *string) (bool, error) {
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, syncLock); err != nil {
		return false, err
	}
	// coalesce keeps the first of two concurrent uploads of the same file.
	var itemID uuid.UUID
	err = tx.QueryRow(ctx, `
		UPDATE attachments SET uploaded_at = coalesce(uploaded_at, $2), thumbnail_key = coalesce(thumbnail_key, $3)
		WHERE id = $1 AND deleted_at IS NULL RETURNING item_id`, id, a.now(), thumbnailKey).Scan(&itemID)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE items SET seq = nextval('sync_seq') WHERE id = $1`, itemID); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

func (a *syncAPI) download(w http.ResponseWriter, r *http.Request) {
	var fileKey, filename, mimeType string
	var uploadedAt time.Time
	found := a.lookup(w, r, `
		SELECT file_key, filename, mime_type, uploaded_at FROM attachments
		WHERE id = $1 AND deleted_at IS NULL AND uploaded_at IS NOT NULL`,
		&fileKey, &filename, &mimeType, &uploadedAt)
	if !found {
		return
	}
	// The filename is client-supplied; FormatMediaType quotes or encodes it, and gives "" if it can't.
	disposition := mime.FormatMediaType("attachment", map[string]string{"filename": filename})
	if disposition == "" {
		disposition = "attachment"
	}
	w.Header().Set("Content-Type", mimeType)
	w.Header().Set("Content-Disposition", disposition)
	a.serveFile(w, r, fileKey, uploadedAt)
}

func (a *syncAPI) thumbnail(w http.ResponseWriter, r *http.Request) {
	var thumbnailKey string
	var uploadedAt time.Time
	found := a.lookup(w, r, `
		SELECT thumbnail_key, uploaded_at FROM attachments
		WHERE id = $1 AND deleted_at IS NULL AND thumbnail_key IS NOT NULL`,
		&thumbnailKey, &uploadedAt)
	if !found {
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	a.serveFile(w, r, thumbnailKey, uploadedAt)
}

// lookup scans the row query selects for the path's Attachment id, answering 404 or 500 itself if there is none.
func (a *syncAPI) lookup(w http.ResponseWriter, r *http.Request, query string, dest ...any) bool {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		http.NotFound(w, r)
		return false
	}
	err = a.db.QueryRow(r.Context(), query, id).Scan(dest...)
	switch {
	case err == nil:
		return true
	case errors.Is(err, pgx.ErrNoRows):
		http.NotFound(w, r)
	default:
		log.Printf("%s %s: %v", r.Method, r.URL.Path, err)
		w.WriteHeader(http.StatusInternalServerError)
	}
	return false
}

// serveFile streams the file, answering Range requests, and never lets a browser guess another type.
func (a *syncAPI) serveFile(w http.ResponseWriter, r *http.Request, key string, modified time.Time) {
	f, err := a.files.Open(key)
	if err != nil {
		log.Printf("%s %s: %v", r.Method, r.URL.Path, err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	defer f.Close()
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, "", modified, f)
}
