package server

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// Purge permanently removes Items that have been in Trash for trashRetention, forgets old applied_ops,
// then deletes the files no live Attachment needs. main runs it every PurgeInterval.
func (s *Server) Purge(ctx context.Context) error {
	a := s.api
	now := a.now()
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, syncLock); err != nil {
		return err
	}
	// The Items' Attachment rows go with them (ON DELETE CASCADE).
	if _, err := tx.Exec(ctx, `
		WITH purged AS (DELETE FROM items WHERE deleted_at < $1 RETURNING id)
		INSERT INTO tombstones (item_id, seq) SELECT id, nextval('sync_seq') FROM purged`,
		now.Add(-trashRetention)); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `DELETE FROM applied_ops WHERE created_at < $1`, now.Add(-appliedOpRetention)); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}

	// Files go only after their rows are committed, so no live row ever names a missing file.
	rows, _ := a.db.Query(ctx, `
		SELECT file_key FROM attachments WHERE deleted_at IS NULL
		UNION ALL
		SELECT thumbnail_key FROM attachments WHERE deleted_at IS NULL AND thumbnail_key IS NOT NULL`)
	keys, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return err
	}
	keep := map[string]bool{}
	for _, k := range keys {
		keep[k] = true
	}
	return a.files.RemoveLeftovers(keep, now.Add(-leftoverFileMinAge))
}
