package server

import (
	"context"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
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
		INSERT INTO topics (id, name, name_updated_at, name_updated_by, archive_updated_at, archive_updated_by, seq)
		VALUES (gen_random_uuid(), 'Mosaic', now(), gen_random_uuid(), now(), gen_random_uuid(), nextval('sync_seq'))`); err != nil {
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
