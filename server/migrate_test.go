package server

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"net/url"
	"os"
	"testing"
	"time"

	"github.com/jackc/pgx/v5/pgconn"
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
	databaseURL := newTestDatabase(t)

	if err := Migrate(ctx, databaseURL); err != nil {
		t.Fatalf("first migrate: %v", err)
	}
	db := openDB(t, databaseURL)
	if _, err := db.Exec(`INSERT INTO topics (id, name) VALUES (gen_random_uuid(), 'Mosaic')`); err != nil {
		t.Fatalf("insert topic: %v", err)
	}

	if err := Migrate(ctx, databaseURL); err != nil {
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

// Direct inserts until the sync API exists to create Topics through.
func TestTopicNamesAreUniqueIgnoringCase(t *testing.T) {
	ctx := context.Background()
	databaseURL := newTestDatabase(t)
	if err := Migrate(ctx, databaseURL); err != nil {
		t.Fatal(err)
	}
	db := openDB(t, databaseURL)

	if _, err := db.Exec(`INSERT INTO topics (id, name) VALUES (gen_random_uuid(), 'CS 111')`); err != nil {
		t.Fatalf("insert CS 111: %v", err)
	}
	_, err := db.Exec(`INSERT INTO topics (id, name) VALUES (gen_random_uuid(), 'cs 111')`)
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23505" {
		t.Fatalf("insert cs 111 = %v, want unique violation (23505)", err)
	}
}
