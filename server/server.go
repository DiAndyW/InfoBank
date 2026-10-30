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

// Server answers the HTTP API and runs the purge job.
type Server struct {
	http.Handler
	api *syncAPI
}

func New(cfg Config) (*Server, error) {
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
	tokens := uploadTokens{key: []byte(cfg.Secret), now: cfg.Now, domain: uploadTokenDomain}
	thumbnailTokens := uploadTokens{key: []byte(cfg.Secret), now: cfg.Now, domain: thumbnailTokenDomain}
	authed.HandleFunc("POST /attachments/{id}/upload-token", func(w http.ResponseWriter, r *http.Request) { tokens.issue(w, r, api) })
	authed.HandleFunc("POST /attachments/{id}/thumbnail-upload-token", func(w http.ResponseWriter, r *http.Request) { thumbnailTokens.issue(w, r, api) })
	authed.HandleFunc("GET /attachments/{id}", api.download)
	authed.HandleFunc("GET /attachments/{id}/thumbnail", api.thumbnail)

	// Hashing first makes the comparison constant-time regardless of input length.
	secretHash := sha256.Sum256([]byte(cfg.Secret))

	root := http.NewServeMux()
	root.HandleFunc("GET /health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	limiter := newFailureLimiter(cfg.Now)
	authorize := func(next http.Handler, capability *uploadTokens) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ip := clientIP(r)
			if limiter.blocked(ip) {
				w.WriteHeader(http.StatusTooManyRequests)
				return
			}
			token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			tokenHash := sha256.Sum256([]byte(token))
			if !ok || (subtle.ConstantTimeCompare(tokenHash[:], secretHash[:]) != 1 && !(capability != nil && capability.valid(token, r.PathValue("id")))) {
				limiter.recordFailure(ip)
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
	root.Handle("PUT /attachments/{id}", authorize(http.HandlerFunc(api.upload), &tokens))
	root.Handle("PUT /attachments/{id}/thumbnail", authorize(http.HandlerFunc(api.uploadThumbnail), &thumbnailTokens))
	root.Handle("/", authorize(authed, nil))
	return &Server{Handler: root, api: api}, nil
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
