package server

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func issuedToken(t *testing.T, e *syncEnv, id string) string {
	t.Helper()
	rec := e.send("POST", "/attachments/"+id+"/upload-token", nil)
	if rec.Code != 200 {
		t.Fatalf("issue = %d: %s", rec.Code, rec.Body.String())
	}
	var answer struct {
		Token     string    `json:"token"`
		ExpiresAt time.Time `json:"expires_at"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &answer); err != nil {
		t.Fatal(err)
	}
	if answer.Token == "" || !answer.ExpiresAt.Equal(e.clock.Now().Add(24*time.Hour)) {
		t.Fatalf("invalid capability response")
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("credential response can be cached")
	}
	return answer.Token
}

func TestUploadTokenOnlyAuthorizesItsAttachmentPUT(t *testing.T) {
	e := newSyncEnv(t)
	_, id := e.captureFile("one.txt", "text/plain", []byte("one"))
	_, other := e.captureFile("two.txt", "text/plain", []byte("two"))
	token := issuedToken(t, e, id)
	for _, endpoint := range []struct{ method, path string }{{"GET", "/attachments/" + id}, {"GET", "/sync/pull"}, {"POST", "/sync/push"}, {"POST", "/attachments/" + id + "/upload-token"}, {"PUT", "/attachments/" + other}} {
		rec := e.send(endpoint.method, endpoint.path, bytes.NewBufferString("one"), "Authorization", "Bearer "+token)
		if rec.Code != 401 {
			t.Fatalf("capability authorized %s %s: %d", endpoint.method, endpoint.path, rec.Code)
		}
	}
	for range 2 {
		rec := e.send("PUT", "/attachments/"+id, bytes.NewBufferString("one"), "Authorization", "Bearer "+token)
		if rec.Code != 204 {
			t.Fatalf("upload/retry = %d", rec.Code)
		}
	}
	if got := e.send("GET", "/attachments/"+id, nil); got.Code != 200 || got.Body.String() != "one" {
		t.Fatal("uploaded bytes differ")
	}
}

func TestUploadTokenRejectsTamperingAndExpiresAtBoundary(t *testing.T) {
	e := newSyncEnv(t)
	_, id := e.captureFile("x", "text/plain", []byte("x"))
	token := issuedToken(t, e, id)
	for _, bad := range []string{token + "x", token[:len(token)-4] + "AAAA", "", strings.Repeat("a", 1000)} {
		if got := e.send("PUT", "/attachments/"+id, bytes.NewBufferString("x"), "Authorization", "Bearer "+bad).Code; got != 401 {
			t.Fatalf("bad token = %d", got)
		}
	}
	e.clock.Advance(24 * time.Hour)
	if got := e.send("PUT", "/attachments/"+id, bytes.NewBufferString("x"), "Authorization", "Bearer "+token).Code; got != 401 {
		t.Fatalf("expired = %d", got)
	}
}

func TestUploadTokenSurvivesRestartButNotSecretRotation(t *testing.T) {
	e := newSyncEnv(t)
	_, id := e.captureFile("x", "text/plain", []byte("x"))
	token := issuedToken(t, e, id)
	for _, secret := range []string{testSecret, strings.Repeat("other-secret", 4)} {
		h, err := New(Config{Secret: secret, Now: e.clock.Now, DB: e.h.api.db, AttachmentDir: e.dir})
		if err != nil {
			t.Fatal(err)
		}
		e.h = h
		got := e.send("PUT", "/attachments/"+id, bytes.NewBufferString("x"), "Authorization", "Bearer "+token).Code
		want := 204
		if secret != testSecret {
			want = 401
		}
		if got != want {
			t.Fatalf("restart/rotation=%d want%d", got, want)
		}
	}
}

func TestUploadTokenRequiresLiveMetadataAndAccountAuthorization(t *testing.T) {
	e := newSyncEnv(t)
	id := uuid.NewString()
	if got := e.send("POST", "/attachments/"+id+"/upload-token", nil).Code; got != 404 {
		t.Fatalf("missing=%d", got)
	}
	_, id = e.captureFile("x", "text/plain", []byte("x"))
	if got := e.send("POST", "/attachments/"+id+"/upload-token", nil, "Authorization", "Bearer wrong").Code; got != 401 {
		t.Fatalf("unauthorized issuance=%d", got)
	}
	token := issuedToken(t, e, id)
	if _, err := e.h.api.db.Exec(t.Context(), "UPDATE attachments SET deleted_at = now() WHERE id = $1", id); err != nil {
		t.Fatal(err)
	}
	if got := e.send("POST", "/attachments/"+id+"/upload-token", nil).Code; got != 404 {
		t.Fatalf("removed issuance=%d", got)
	}
	if got := e.send("PUT", "/attachments/"+id, bytes.NewBufferString("x"), "Authorization", "Bearer "+token).Code; got != http.StatusGone {
		t.Fatalf("removed upload=%d", got)
	}
}
