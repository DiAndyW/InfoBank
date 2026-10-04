package server

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

const testSecret = "correct-horse-battery-staple-0123456789"

type testClock struct{ now time.Time }

func (c *testClock) Now() time.Time          { return c.now }
func (c *testClock) Advance(d time.Duration) { c.now = c.now.Add(d) }

func newTestServer(t *testing.T) (http.Handler, *testClock) {
	t.Helper()
	clock := &testClock{now: time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)}
	h, err := New(Config{Secret: testSecret, Now: clock.Now})
	if err != nil {
		t.Fatal(err)
	}
	return h, clock
}

func TestShortSecretIsRefused(t *testing.T) {
	for _, secret := range []string{"", "short", testSecret[:31]} {
		if _, err := New(Config{Secret: secret, Now: time.Now}); err == nil {
			t.Errorf("New with %d-char secret succeeded, want error", len(secret))
		}
	}
}

// request sends method+path from remoteAddr, with a bearer token when secret != "".
func request(h http.Handler, method, path, remoteAddr, secret string, header ...string) int {
	req := httptest.NewRequest(method, path, nil)
	req.RemoteAddr = remoteAddr
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	for i := 0; i+1 < len(header); i += 2 {
		req.Header.Set(header[i], header[i+1])
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Code
}

func TestHealthNeedsNoSecret(t *testing.T) {
	h, _ := newTestServer(t)
	if got := request(h, "GET", "/health", "203.0.113.1:5000", ""); got != http.StatusOK {
		t.Fatalf("GET /health = %d, want 200", got)
	}
}

func TestSecretGatesEverythingElse(t *testing.T) {
	h, _ := newTestServer(t)
	cases := []struct {
		name   string
		secret string
		want   int
	}{
		{"correct secret", testSecret, http.StatusNoContent},
		{"missing secret", "", http.StatusUnauthorized},
		{"wrong secret", "hunter2", http.StatusUnauthorized},
		{"secret prefix", testSecret[:5], http.StatusUnauthorized},
	}
	for _, c := range cases {
		if got := request(h, "GET", "/auth/check", "203.0.113.1:5000", c.secret); got != c.want {
			t.Errorf("%s: GET /auth/check = %d, want %d", c.name, got, c.want)
		}
	}
}

func TestRepeatedFailuresBlockTheIPUntilTheWindowEnds(t *testing.T) {
	h, clock := newTestServer(t)
	attacker := "203.0.113.9:5000"
	for i := range 10 {
		if got := request(h, "GET", "/auth/check", attacker, "guess"); got != http.StatusUnauthorized {
			t.Fatalf("failed attempt %d = %d, want 401", i+1, got)
		}
	}

	if got := request(h, "GET", "/auth/check", attacker, testSecret); got != http.StatusTooManyRequests {
		t.Fatalf("correct secret after 10 failures = %d, want 429", got)
	}
	if got := request(h, "GET", "/auth/check", "198.51.100.7:5000", testSecret); got != http.StatusNoContent {
		t.Fatalf("other IP while attacker blocked = %d, want 204", got)
	}
	if got := request(h, "GET", "/health", attacker, ""); got != http.StatusOK {
		t.Fatalf("/health while blocked = %d, want 200", got)
	}

	clock.Advance(14 * time.Minute)
	if got := request(h, "GET", "/auth/check", attacker, testSecret); got != http.StatusTooManyRequests {
		t.Fatalf("correct secret 14m later = %d, want 429", got)
	}

	clock.Advance(1 * time.Minute)
	if got := request(h, "GET", "/auth/check", attacker, testSecret); got != http.StatusNoContent {
		t.Fatalf("correct secret 15m later = %d, want 204", got)
	}
}

func TestFailuresSpreadBeyondTheWindowDoNotBlock(t *testing.T) {
	h, clock := newTestServer(t)
	ip := "203.0.113.9:5000"
	for range 9 {
		request(h, "GET", "/auth/check", ip, "typo")
	}
	clock.Advance(15 * time.Minute)
	request(h, "GET", "/auth/check", ip, "typo")
	if got := request(h, "GET", "/auth/check", ip, testSecret); got != http.StatusNoContent {
		t.Fatalf("correct secret after 9 old + 1 new failure = %d, want 204", got)
	}
}

func TestBehindProxyTheForwardedClientIsWhatGetsBlocked(t *testing.T) {
	h, _ := newTestServer(t)
	proxy := "127.0.0.1:41000"
	for range 10 {
		request(h, "GET", "/auth/check", proxy, "guess", "X-Forwarded-For", "203.0.113.9")
	}
	if got := request(h, "GET", "/auth/check", proxy, testSecret, "X-Forwarded-For", "203.0.113.9"); got != http.StatusTooManyRequests {
		t.Fatalf("blocked client via proxy = %d, want 429", got)
	}
	if got := request(h, "GET", "/auth/check", proxy, testSecret, "X-Forwarded-For", "198.51.100.7"); got != http.StatusNoContent {
		t.Fatalf("different client via same proxy = %d, want 204", got)
	}
	// A client-supplied X-Forwarded-For arrives first in the list; the proxy appends the real IP last.
	if got := request(h, "GET", "/auth/check", proxy, testSecret, "X-Forwarded-For", "198.51.100.7, 203.0.113.9"); got != http.StatusTooManyRequests {
		t.Fatalf("blocked client prepending a fake IP = %d, want 429", got)
	}
}

func TestDirectCallerCannotSpoofForwardedFor(t *testing.T) {
	h, _ := newTestServer(t)
	attacker := "203.0.113.9:5000"
	for i := range 10 {
		request(h, "GET", "/auth/check", attacker, "guess", "X-Forwarded-For", fmt.Sprintf("10.0.0.%d", i))
	}
	if got := request(h, "GET", "/auth/check", attacker, testSecret, "X-Forwarded-For", "10.0.0.99"); got != http.StatusTooManyRequests {
		t.Fatalf("direct attacker rotating X-Forwarded-For = %d, want 429", got)
	}
}

func TestUnknownPathStillNeedsSecret(t *testing.T) {
	h, _ := newTestServer(t)
	if got := request(h, "GET", "/nope", "203.0.113.1:5000", ""); got != http.StatusUnauthorized {
		t.Fatalf("GET /nope without secret = %d, want 401", got)
	}
}
