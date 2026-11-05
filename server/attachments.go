package server

import (
	"bytes"
	"context"
	"errors"
	"image/jpeg"
	"io"
	"io/fs"
	"log"
	"mime"
	"net/http"
	"strings"
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
		missing, err := a.invalidateMissingFile(r.Context(), fileKey, true)
		if err != nil {
			log.Printf("upload: stored original unavailable: %v", err)
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if !missing {
			w.WriteHeader(http.StatusNoContent)
			return
		}
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
	live, err := a.publishAttachment(r.Context(), id, thumbnailKey, true)
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

// Publishing either upload bumps the Item's seq so Devices re-pull its Attachment flags.
func (a *syncAPI) publishAttachment(ctx context.Context, id uuid.UUID, thumbnailKey *string, original bool) (bool, error) {
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
		UPDATE attachments SET uploaded_at = CASE WHEN $4 THEN coalesce(uploaded_at, $2) ELSE uploaded_at END,
		thumbnail_key = coalesce(thumbnail_key, $3)
		WHERE id = $1 AND deleted_at IS NULL AND ($4 OR thumbnail_key IS NULL)
		RETURNING item_id`, id, a.now(), thumbnailKey, original).Scan(&itemID)
	if errors.Is(err, pgx.ErrNoRows) {
		var live bool
		err = tx.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM attachments WHERE id = $1 AND deleted_at IS NULL)", id).Scan(&live)
		return live, err
	}
	if err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE items SET seq = nextval('sync_seq') WHERE id = $1`, itemID); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}

func (a *syncAPI) uploadThumbnail(w http.ResponseWriter, r *http.Request) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	var mimeType string
	var removed bool
	var thumbnailKey *string
	err = a.db.QueryRow(r.Context(), "SELECT mime_type, deleted_at IS NOT NULL, thumbnail_key FROM attachments WHERE id = $1", id).Scan(&mimeType, &removed, &thumbnailKey)
	switch {
	case errors.Is(err, pgx.ErrNoRows):
		http.NotFound(w, r)
		return
	case err != nil:
		w.WriteHeader(http.StatusInternalServerError)
		return
	case removed:
		w.WriteHeader(http.StatusGone)
		return
	case !strings.HasPrefix(mimeType, "image/") && !strings.HasPrefix(mimeType, "video/"):
		w.WriteHeader(http.StatusUnsupportedMediaType)
		return
	}
	contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
	if err != nil || contentType != "image/jpeg" {
		w.WriteHeader(http.StatusUnsupportedMediaType)
		return
	}
	if thumbnailKey != nil {
		missing, err := a.invalidateMissingFile(r.Context(), *thumbnailKey, false)
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		if !missing {
			w.WriteHeader(http.StatusNoContent)
			return
		}
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxThumbnailUploadBytes+1))
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	if len(body) > maxThumbnailUploadBytes {
		w.WriteHeader(http.StatusRequestEntityTooLarge)
		return
	}
	config, err := jpeg.DecodeConfig(bytes.NewReader(body))
	if err != nil || config.Width <= 0 || config.Height <= 0 || config.Width > maxThumbnailUploadEdgePixels || config.Height > maxThumbnailUploadEdgePixels {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	preview := thumbnailJPEG(bytes.NewReader(body))
	if preview == nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	key := uuid.NewString()
	if err := a.files.Put(key, bytes.NewReader(preview), int64(len(preview))); err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	live, err := a.publishAttachment(r.Context(), id, &key, false)
	switch {
	case err != nil:
		w.WriteHeader(http.StatusInternalServerError)
	case !live:
		w.WriteHeader(http.StatusGone)
	default:
		w.WriteHeader(http.StatusNoContent)
	}
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
	a.serveFile(w, r, fileKey, uploadedAt, true)
}

func (a *syncAPI) thumbnail(w http.ResponseWriter, r *http.Request) {
	var thumbnailKey string
	var uploadedAt time.Time
	found := a.lookup(w, r, `
		SELECT thumbnail_key, uploaded_at FROM attachments
		WHERE id = $1 AND deleted_at IS NULL AND thumbnail_key IS NOT NULL AND uploaded_at IS NOT NULL`,
		&thumbnailKey, &uploadedAt)
	if !found {
		return
	}
	w.Header().Set("Content-Type", "image/jpeg")
	a.serveFile(w, r, thumbnailKey, uploadedAt, false)
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
func (a *syncAPI) serveFile(w http.ResponseWriter, r *http.Request, key string, modified time.Time, original bool) {
	f, err := a.files.Open(key)
	if err != nil {
		log.Printf("%s %s: %v", r.Method, r.URL.Path, err)
		if errors.Is(err, fs.ErrNotExist) {
			if _, err := a.invalidateMissingFile(r.Context(), key, original); err != nil {
				log.Printf("attachment recovery: %v", err)
			}
		}
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	defer f.Close()
	w.Header().Set("X-Content-Type-Options", "nosniff")
	http.ServeContent(w, r, "", modified, f)
}

// Rechecking under the publication lock prevents a stale request from undoing a completed upload.
func (a *syncAPI) invalidateMissingFile(ctx context.Context, key string, original bool) (bool, error) {
	f, err := a.files.Open(key)
	if err == nil {
		f.Close()
		return false, nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return false, err
	}
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return false, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, syncLock); err != nil {
		return false, err
	}
	f, err = a.files.Open(key)
	if err == nil {
		f.Close()
		return false, nil
	}
	if !errors.Is(err, fs.ErrNotExist) {
		return false, err
	}
	query := `UPDATE attachments SET thumbnail_key = NULL WHERE thumbnail_key = $1 AND deleted_at IS NULL RETURNING item_id`
	if original {
		query = `UPDATE attachments SET uploaded_at = NULL WHERE file_key = $1 AND uploaded_at IS NOT NULL AND deleted_at IS NULL RETURNING item_id`
	}
	var itemID uuid.UUID
	err = tx.QueryRow(ctx, query, key).Scan(&itemID)
	if errors.Is(err, pgx.ErrNoRows) {
		return true, nil
	}
	if err != nil {
		return false, err
	}
	if _, err := tx.Exec(ctx, `UPDATE items SET seq = nextval('sync_seq') WHERE id = $1`, itemID); err != nil {
		return false, err
	}
	return true, tx.Commit(ctx)
}
