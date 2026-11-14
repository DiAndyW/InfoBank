package server

import (
	"context"
	"fmt"
	"io/fs"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/jackc/pgx/v5/stdlib"
	"github.com/pressly/goose/v3"
)

// newTestDatabase creates an empty database for one test and drops it afterwards.
// NOTEBANK_TEST_ADMIN_URL points at a server where the user may CREATE DATABASE.
func newTestDatabase(t *testing.T) string {
	t.Helper()
	ctx := context.Background()
	adminURL := os.Getenv("NOTEBANK_TEST_ADMIN_URL")
	if adminURL == "" {
		adminURL = "postgres:///postgres"
	}
	admin, err := pgx.Connect(ctx, adminURL)
	if err != nil {
		t.Fatalf("connect (is Postgres running? set NOTEBANK_TEST_ADMIN_URL): %v", err)
	}
	t.Cleanup(func() { admin.Close(ctx) })

	name := fmt.Sprintf("notebank_test_%d", time.Now().UnixNano())
	if _, err := admin.Exec(ctx, "CREATE DATABASE "+name); err != nil {
		t.Fatalf("create test database: %v", err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec(ctx, "DROP DATABASE "+name+" WITH (FORCE)"); err != nil {
			t.Errorf("drop test database: %v", err)
		}
	})

	u, err := url.Parse(adminURL)
	if err != nil {
		t.Fatal(err)
	}
	u.Path = "/" + name
	return u.String()
}

func openPool(t *testing.T, databaseURL string) *pgxpool.Pool {
	t.Helper()
	pool, err := pgxpool.New(context.Background(), databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pool.Close)
	return pool
}

func TestMigrateTwiceKeepsData(t *testing.T) {
	ctx := context.Background()
	pool := openPool(t, newTestDatabase(t))

	if err := Migrate(ctx, pool); err != nil {
		t.Fatalf("first migrate: %v", err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO topics (id, name, name_updated_at, name_updated_by, activity_at, seq)
		VALUES (gen_random_uuid(), 'Mosaic', now(), gen_random_uuid(), now(), nextval('sync_seq'))`); err != nil {
		t.Fatalf("insert topic: %v", err)
	}

	if err := Migrate(ctx, pool); err != nil {
		t.Fatalf("second migrate: %v", err)
	}
	var count int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM topics WHERE name = 'Mosaic'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("topics named Mosaic after second migrate = %d, want 1", count)
	}
}

func TestRemoveArchiveMigration(t *testing.T) {
	ctx := context.Background()
	pool := openPool(t, newTestDatabase(t))
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	dir, err := fs.Sub(migrations, "migrations")
	if err != nil {
		t.Fatal(err)
	}
	provider, err := goose.NewProvider(goose.DialectPostgres, db, dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := provider.UpTo(ctx, 6); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `
		INSERT INTO topics (id, name, archived_at, name_updated_at, name_updated_by, archive_updated_at, archive_updated_by, seq)
		VALUES (gen_random_uuid(), 'Archived', now(), now(), gen_random_uuid(), now(), gen_random_uuid(), nextval('sync_seq')),
		       (gen_random_uuid(), 'Open', NULL, now(), gen_random_uuid(), now(), gen_random_uuid(), nextval('sync_seq'))`); err != nil {
		t.Fatal(err)
	}
	var maxSeq, openSeq int64
	if err := pool.QueryRow(ctx, `SELECT max(seq) FROM topics`).Scan(&maxSeq); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT seq FROM topics WHERE name = 'Open'`).Scan(&openSeq); err != nil {
		t.Fatal(err)
	}
	if _, err := provider.UpTo(ctx, 7); err != nil {
		t.Fatal(err)
	}
	var archivedAfter, openAfter int64
	if err := pool.QueryRow(ctx, `SELECT seq FROM topics WHERE name = 'Archived'`).Scan(&archivedAfter); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT seq FROM topics WHERE name = 'Open'`).Scan(&openAfter); err != nil {
		t.Fatal(err)
	}
	if archivedAfter <= maxSeq {
		t.Errorf("archived Topic seq = %d, want > %d", archivedAfter, maxSeq)
	}
	if openAfter != openSeq {
		t.Errorf("open Topic seq = %d, want %d", openAfter, openSeq)
	}
	var columns int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'topics' AND column_name IN ('archived_at', 'archive_updated_at', 'archive_updated_by')`).Scan(&columns); err != nil {
		t.Fatal(err)
	}
	if columns != 0 {
		t.Errorf("archive columns remaining = %d, want 0", columns)
	}
	if _, err := provider.DownTo(ctx, 6); err != nil {
		t.Fatal(err)
	}
	var restored int
	if err := pool.QueryRow(ctx, `SELECT count(*) FROM topics WHERE archived_at IS NULL AND archive_updated_at = name_updated_at AND archive_updated_by = name_updated_by`).Scan(&restored); err != nil {
		t.Fatal(err)
	}
	if restored != 2 {
		t.Errorf("restored archive defaults on %d Topics, want 2", restored)
	}
	if _, err := provider.UpTo(ctx, 7); err != nil {
		t.Fatal(err)
	}
	if err := pool.QueryRow(ctx, `SELECT seq FROM topics WHERE name = 'Archived'`).Scan(&archivedAfter); err != nil {
		t.Fatal(err)
	}
	if archivedAfter <= maxSeq {
		t.Errorf("round-trip Topic seq = %d, want > %d", archivedAfter, maxSeq)
	}
}

func TestTopicActivityMigration(t *testing.T) {
	ctx := context.Background()
	pool := openPool(t, newTestDatabase(t))
	db := stdlib.OpenDBFromPool(pool)
	defer db.Close()
	dir, err := fs.Sub(migrations, "migrations")
	if err != nil {
		t.Fatal(err)
	}
	provider, err := goose.NewProvider(goose.DialectPostgres, db, dir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := provider.UpTo(ctx, 7); err != nil {
		t.Fatal(err)
	}
	if _, err := pool.Exec(ctx, `
 INSERT INTO topics (id, name, created_at, name_updated_at, name_updated_by, seq)
 SELECT gen_random_uuid(), name, '2026-10-01T00:00:00Z'::timestamptz, '2026-10-01T00:00:00Z'::timestamptz, gen_random_uuid(), nextval('sync_seq')
 FROM unnest(ARRAY['Empty', 'Populated', 'Deleted', 'Older']) name;
 UPDATE topics SET deleted_at = now() WHERE name = 'Deleted';
 INSERT INTO items (id, topic_id, text, capture_time, deleted_at, text_updated_at, text_updated_by, topic_updated_at, topic_updated_by, trash_updated_at, trash_updated_by, seq)
 SELECT gen_random_uuid(), topics.id, 'item', capture_time, captures.deleted_at, capture_time, gen_random_uuid(), capture_time, gen_random_uuid(), capture_time, gen_random_uuid(), nextval('sync_seq')
 FROM topics CROSS JOIN (VALUES ('2026-10-02T00:00:00Z'::timestamptz, NULL::timestamptz), ('2026-10-03T00:00:00Z'::timestamptz, now())) AS captures(capture_time, deleted_at)
 WHERE name = 'Populated';
 INSERT INTO items (id, topic_id, text, capture_time, text_updated_at, text_updated_by, topic_updated_at, topic_updated_by, trash_updated_at, trash_updated_by, seq)
 SELECT gen_random_uuid(), id, 'older', '2026-09-01T00:00:00Z', now(), gen_random_uuid(), now(), gen_random_uuid(), now(), gen_random_uuid(), nextval('sync_seq') FROM topics WHERE name = 'Older'
 `); err != nil {
		t.Fatal(err)
	}
	var maxSeq int64
	if err := pool.QueryRow(ctx, `SELECT last_value FROM sync_seq`).Scan(&maxSeq); err != nil {
		t.Fatal(err)
	}
	for round := 0; round < 2; round++ {
		if _, err := provider.Up(ctx); err != nil {
			t.Fatal(err)
		}
		var columns int
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM information_schema.columns WHERE table_name = 'topics' AND column_name = 'activity_at' AND is_nullable = 'NO'`).Scan(&columns); err != nil {
			t.Fatal(err)
		}
		if columns != 1 {
			t.Fatalf("NOT NULL activity_at columns = %d, want 1", columns)
		}
		rows, err := pool.Query(ctx, `SELECT name, activity_at, seq FROM topics`)
		if err != nil {
			t.Fatal(err)
		}
		count := 0
		for rows.Next() {
			var name string
			var activity time.Time
			var seq int64
			if err := rows.Scan(&name, &activity, &seq); err != nil {
				t.Fatal(err)
			}
			want := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
			if name == "Populated" {
				want = want.Add(48 * time.Hour)
			}
			if !activity.Equal(want) {
				t.Errorf("%s activity_at = %v, want %v", name, activity, want)
			}
			if seq <= maxSeq {
				t.Errorf("%s seq = %d, want > %d", name, seq, maxSeq)
			}
			count++
		}
		if err := rows.Err(); err != nil {
			t.Fatal(err)
		}
		rows.Close()
		if count != 4 {
			t.Fatalf("Topics = %d, want 4", count)
		}
		if err := pool.QueryRow(ctx, `SELECT max(seq) FROM topics`).Scan(&maxSeq); err != nil {
			t.Fatal(err)
		}
		if _, err := provider.DownTo(ctx, 7); err != nil {
			t.Fatal(err)
		}
		if err := pool.QueryRow(ctx, `SELECT count(*) FROM information_schema.columns WHERE table_name = 'topics' AND column_name = 'activity_at'`).Scan(&columns); err != nil {
			t.Fatal(err)
		}
		if columns != 0 {
			t.Fatalf("activity_at still present after Down")
		}
	}
	if _, err := provider.Up(ctx); err != nil {
		t.Fatal(err)
	}
}
