package server

import (
	"context"
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
)

// syncLock serializes every write that takes a sync_seq value, so they commit in order and a pull cursor never skips one.
const syncLock = 7001

func (a *syncAPI) push(w http.ResponseWriter, r *http.Request) {
	// Ops stay raw so one malformed op is rejected on its own instead of failing the batch on every retry.
	var req struct {
		DeviceID uuid.UUID         `json:"device_id"`
		Ops      []json.RawMessage `json:"ops"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxPushBodyBytes)).Decode(&req); err != nil {
		if _, tooBig := errors.AsType[*http.MaxBytesError](err); tooBig {
			http.Error(w, "push too large", http.StatusRequestEntityTooLarge)
			return
		}
		http.Error(w, "malformed push", http.StatusBadRequest)
		return
	}
	if req.DeviceID == uuid.Nil || len(req.Ops) > maxPushOps {
		http.Error(w, "missing device_id or too many ops", http.StatusBadRequest)
		return
	}

	results, err := a.applyAll(r.Context(), req.DeviceID, req.Ops)
	if err != nil {
		log.Printf("push: %v", err)
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	writeJSON(w, map[string]any{"results": results})
}

func (a *syncAPI) applyAll(ctx context.Context, device uuid.UUID, ops []json.RawMessage) ([]opResult, error) {
	tx, err := a.db.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock($1)`, syncLock); err != nil {
		return nil, err
	}

	b := &batch{ctx: ctx, tx: tx, device: device, now: a.now().Truncate(time.Microsecond)}
	results := make([]opResult, len(ops))
	for i, raw := range ops {
		var o pushOp
		if json.Unmarshal(raw, &o) != nil || o.ID == uuid.Nil {
			results[i] = rejected("invalid") // without an id there's nothing to record for replay
			continue
		}
		res, err := b.applyOnce(o)
		if err != nil {
			return nil, err
		}
		results[i] = res
	}
	return results, tx.Commit(ctx)
}

// applyOnce returns a replayed op's first result instead of applying it again.
func (b *batch) applyOnce(o pushOp) (opResult, error) {
	var stored []byte
	err := b.tx.QueryRow(b.ctx, `SELECT result FROM applied_ops WHERE op_id = $1`, o.ID).Scan(&stored)
	if err == nil {
		var res opResult
		return res, json.Unmarshal(stored, &res)
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return opResult{}, err
	}

	res, err := b.apply(o)
	if err != nil {
		return opResult{}, err
	}
	res.OpID = o.ID
	stored, err = json.Marshal(res)
	if err != nil {
		return opResult{}, err
	}
	_, err = b.tx.Exec(b.ctx, `INSERT INTO applied_ops (op_id, result) VALUES ($1, $2)`, o.ID, stored)
	return res, err
}

func (b *batch) apply(o pushOp) (opResult, error) {
	if o.At.IsZero() {
		return rejected("invalid"), nil
	}
	// Postgres keeps microseconds; truncating first keeps comparisons stable across a round trip.
	at := o.At.Truncate(time.Microsecond)
	if at.After(b.now) {
		at = b.now
	}
	s := stamp{at: at, by: b.device}

	switch o.Type {
	case "CaptureItem":
		return b.captureItem(o, s)
	case "CreateTopic":
		return b.createTopic(o, s)
	case "RenameTopic", "ArchiveTopic", "UnarchiveTopic", "DeleteTopic":
		return b.changeTopic(o, s)
	}
	return b.changeItem(o, s)
}

// storable reports whether s is non-empty, at most maxBytes, and free of NUL, which Postgres text can't hold.
func storable(s string, maxBytes int) bool {
	return s != "" && len(s) <= maxBytes && !strings.ContainsRune(s, 0)
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("write response: %v", err)
	}
}
