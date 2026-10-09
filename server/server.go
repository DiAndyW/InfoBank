package server

import (
	"crypto/sha256"
	"crypto/subtle"
	"fmt"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

type Config struct {
	Secret string
	Now    func() time.Time
	DB     *pgxpool.Pool
	// AttachmentDir must already exist; the Server never creates it, so a typo can't hide files somewhere new.
	AttachmentDir string
}

func New(cfg Config) (http.Handler, error) {
	if len(cfg.Secret) < minSecretChars {
		return nil, fmt.Errorf("secret must be at least %d characters (try: openssl rand -base64 32)", minSecretChars)
	}

	files, err := openAttachmentStore(cfg.AttachmentDir)
	if err != nil {
		return nil, fmt.Errorf("attachment directory: %w", err)
	}

	authed := http.NewServeMux()
	authed.HandleFunc("GET /auth/check", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})
	api := &syncAPI{db: cfg.DB, now: cfg.Now, files: files}
	authed.HandleFunc("POST /sync/push", api.push)
	authed.HandleFunc("GET /sync/pull", api.pull)
	authed.HandleFunc("PUT /attachments/{id}", api.upload)
	authed.HandleFunc("GET /attachments/{id}", api.download)
	authed.HandleFunc("GET /attachments/{id}/thumbnail", api.thumbnail)

	// Hashing first makes the comparison constant-time regardless of input length.
	secretHash := sha256.Sum256([]byte(cfg.Secret))

	root := http.NewServeMux()
	root.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	limiter := newFailureLimiter(cfg.Now)
	root.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		ip := clientIP(r)
		if limiter.blocked(ip) {
			w.WriteHeader(http.StatusTooManyRequests)
			return
		}
		token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		tokenHash := sha256.Sum256([]byte(token))
		if !ok || subtle.ConstantTimeCompare(tokenHash[:], secretHash[:]) != 1 {
			limiter.recordFailure(ip)
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		authed.ServeHTTP(w, r)
	})
	return root, nil
}

// clientIP trusts X-Forwarded-For only from loopback (Caddy), and only its last entry, which Caddy appends.
func clientIP(r *http.Request) string {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	if ip := net.ParseIP(host); ip == nil || !ip.IsLoopback() {
		return host
	}
	forwarded := r.Header.Values("X-Forwarded-For")
	if len(forwarded) == 0 {
		return host
	}
	entries := strings.Split(forwarded[len(forwarded)-1], ",")
	return strings.TrimSpace(entries[len(entries)-1])
}
