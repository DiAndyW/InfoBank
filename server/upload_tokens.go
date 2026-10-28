package server

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"net/http"
	"time"

	"github.com/google/uuid"
)

const uploadTokenLifetime = 24 * time.Hour
const uploadTokenDomain = "notebank/attachment-upload/v1\x00"

type uploadTokens struct {
	key []byte
	now func() time.Time
}

func (u uploadTokens) signature(payload []byte) []byte {
	mac := hmac.New(sha256.New, u.key)
	mac.Write([]byte(uploadTokenDomain))
	mac.Write(payload)
	return mac.Sum(nil)
}

func (u uploadTokens) issue(w http.ResponseWriter, r *http.Request, a *syncAPI) {
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	var exists bool
	if err := a.db.QueryRow(r.Context(), "SELECT EXISTS(SELECT 1 FROM attachments WHERE id = $1 AND deleted_at IS NULL)", id).Scan(&exists); err != nil {
		w.WriteHeader(500)
		return
	}
	if !exists {
		http.NotFound(w, r)
		return
	}
	expires := u.now().UTC().Truncate(time.Second).Add(uploadTokenLifetime)
	payload := make([]byte, 24, 56)
	copy(payload, id[:])
	binary.BigEndian.PutUint64(payload[16:], uint64(expires.Unix()))
	token := base64.RawURLEncoding.EncodeToString(append(payload, u.signature(payload)...))
	w.Header().Set("Cache-Control", "no-store")
	writeJSON(w, map[string]any{"token": token, "expires_at": expires})
}

func (u uploadTokens) valid(token, idText string) bool {
	if len(token) != 75 {
		return false
	}
	decoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil || len(decoded) != 56 {
		return false
	}
	id, err := uuid.Parse(idText)
	if err != nil {
		return false
	}
	payload := decoded[:24]
	return hmac.Equal(decoded[24:], u.signature(payload)) && hmac.Equal(payload[:16], id[:]) && binary.BigEndian.Uint64(payload[16:]) > uint64(u.now().Unix())
}
