package server

import (
	"context"
	"database/sql"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	_ "github.com/jackc/pgx/v5/stdlib"
)

// newTestDatabase creates an empty database for one test and drops it afterwards.
// NOTEBANK_TEST_ADMIN_URL points at a server where the user may CREATE DATABASE.
func newTestDatabase(t *testing.T) string {
	t.Helper()
	adminURL := os.Getenv("NOTEBANK_TEST_ADMIN_URL")
	if adminURL == "" {
		adminURL = "postgres:///postgres"
	}
	admin, err := sql.Open("pgx", adminURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { admin.Close() })

	name := fmt.Sprintf("notebank_test_%d", time.Now().UnixNano())
	if _, err := admin.Exec("CREATE DATABASE " + name); err != nil {
		t.Fatalf("create test database (is Postgres running? set NOTEBANK_TEST_ADMIN_URL): %v", err)
	}
	t.Cleanup(func() {
		if _, err := admin.Exec("DROP DATABASE " + name + " WITH (FORCE)"); err != nil {
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

func openDB(t *testing.T, databaseURL string) *sql.DB {
	t.Helper()
	db, err := sql.Open("pgx", databaseURL)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	return db
}

func TestMigrateTwiceKeepsData(t *testing.T) {
	ctx := context.Background()
	db := openDB(t, newTestDatabase(t))

	if err := Migrate(ctx, db); err != nil {
		t.Fatalf("first migrate: %v", err)
	}
	if _, err := db.Exec(`
		INSERT INTO topics (id, name, name_updated_at, name_updated_by, archive_updated_at, archive_updated_by, seq)
		VALUES (gen_random_uuid(), 'Mosaic', now(), gen_random_uuid(), now(), gen_random_uuid(), nextval('sync_seq'))`); err != nil {
		t.Fatalf("insert topic: %v", err)
	}

	if err := Migrate(ctx, db); err != nil {
		t.Fatalf("second migrate: %v", err)
	}
	var count int
	if err := db.QueryRow(`SELECT count(*) FROM topics WHERE name = 'Mosaic'`).Scan(&count); err != nil {
		t.Fatal(err)
	}
	if count != 1 {
		t.Fatalf("topics named Mosaic after second migrate = %d, want 1", count)
	}
}
