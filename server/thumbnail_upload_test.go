package server

import (
	"bytes"
	"encoding/json"
	"image"
	"image/jpeg"
	"net/http"
	"testing"
	"time"
)

func jpegPreview(t *testing.T, width, height int) []byte {
	t.Helper()
	var output bytes.Buffer
	if err := jpeg.Encode(&output, image.NewRGBA(image.Rect(0, 0, width, height)), nil); err != nil {
		t.Fatal(err)
	}
	return output.Bytes()
}

func thumbnailToken(t *testing.T, e *syncEnv, id string) string {
	t.Helper()
	rec := e.send("POST", "/attachments/"+id+"/thumbnail-upload-token", nil)
	var answer struct {
		Token string `json:"token"`
	}
	if rec.Code != 200 || json.Unmarshal(rec.Body.Bytes(), &answer) != nil || answer.Token == "" {
		t.Fatalf("thumbnail capability = %d %s", rec.Code, rec.Body)
	}
	return answer.Token
}

func TestDeviceJPEGPreviewPublishesWithoutChangingHEICOriginal(t *testing.T) {
	e := newSyncEnv(t)
	original := []byte("HEIC original the Server cannot decode")
	item, id := e.captureFile("photo.heic", "image/heic", original)
	if e.upload(id, original) != 204 {
		t.Fatal("original upload failed")
	}
	cursor := e.pull(0).Cursor
	preview := jpegPreview(t, 600, 300)
	if rec := e.send("PUT", "/attachments/"+id+"/thumbnail", bytes.NewReader(preview), "Content-Type", "image/jpeg", "Authorization", "Bearer "+thumbnailToken(t, e, id)); rec.Code != 204 {
		t.Fatalf("preview upload = %d %s", rec.Code, rec.Body)
	}
	page := e.pull(cursor)
	if len(page.Items) != 1 || page.Items[0].ID != item || !page.Items[0].Attachments[0].HasThumbnail || !page.Items[0].Attachments[0].Uploaded {
		t.Fatalf("preview metadata did not propagate: %+v", page.Items)
	}
	if size := thumbnailSize(t, e.send("GET", "/attachments/"+id+"/thumbnail", nil)); size != image.Pt(400, 200) {
		t.Fatalf("size = %v", size)
	}
	if rec := e.send("GET", "/attachments/"+id, nil); rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), original) {
		t.Fatal("original changed")
	}
}

func TestDeviceJPEGPosterBecomesAVideoThumbnail(t *testing.T) {
	e := newSyncEnv(t)
	original := []byte("QuickTime movie the Server cannot decode")
	item, id := e.captureFile("clip.mov", "video/quicktime", original)
	if e.upload(id, original) != 204 {
		t.Fatal("original upload failed")
	}
	if rec := e.send("PUT", "/attachments/"+id+"/thumbnail", bytes.NewReader(jpegPreview(t, 600, 300)), "Content-Type", "image/jpeg", "Authorization", "Bearer "+thumbnailToken(t, e, id)); rec.Code != 204 {
		t.Fatalf("poster upload = %d %s", rec.Code, rec.Body)
	}
	if !e.item(item).Attachments[0].HasThumbnail {
		t.Fatal("poster was not published")
	}
	if size := thumbnailSize(t, e.send("GET", "/attachments/"+id+"/thumbnail", nil)); size != image.Pt(400, 200) {
		t.Fatalf("size = %v", size)
	}
	if rec := e.send("GET", "/attachments/"+id, nil); rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), original) {
		t.Fatal("original changed")
	}
}

func TestPreviewBeforeOriginalDoesNotMarkOriginalUploadedAndRetryIsIdempotent(t *testing.T) {
	e := newSyncEnv(t)
	item, id := e.captureFile("photo.heic", "image/heic", []byte("original"))
	upload := func(preview []byte) int {
		return e.send("PUT", "/attachments/"+id+"/thumbnail", bytes.NewReader(preview), "Content-Type", "image/jpeg").Code
	}
	if code := upload(jpegPreview(t, 40, 20)); code != 204 {
		t.Fatalf("preview = %d", code)
	}
	if a := e.item(item).Attachments[0]; a.Uploaded || !a.HasThumbnail {
		t.Fatalf("flags = %+v", a)
	}
	if code := e.send("GET", "/attachments/"+id+"/thumbnail", nil).Code; code != 404 {
		t.Fatalf("before original = %d", code)
	}
	if e.upload(id, []byte("original")) != 204 {
		t.Fatal("original upload failed")
	}
	first := e.send("GET", "/attachments/"+id+"/thumbnail", nil).Body.Bytes()
	cursor := e.pull(0).Cursor
	if code := upload(jpegPreview(t, 30, 30)); code != 204 {
		t.Fatalf("retry = %d", code)
	}
	if !bytes.Equal(first, e.send("GET", "/attachments/"+id+"/thumbnail", nil).Body.Bytes()) {
		t.Fatal("retry replaced the first thumbnail")
	}
	if page := e.pull(cursor); len(page.Items) != 0 {
		t.Fatal("idempotent retry bumped the Item sequence")
	}
}

func TestPreviewUploadValidatesUntrustedContent(t *testing.T) {
	for _, test := range []struct {
		name, mime string
		body       []byte
		status     int
	}{
		{"wrong type", "image/png", pngOf(t, 2, 2), 415},
		{"not JPEG", "image/jpeg", []byte("invalid"), 400},
		{"oversized body", "image/jpeg", make([]byte, (1<<20)+1), 413},
		{"oversized dimensions", "image/jpeg", jpegPreview(t, 641, 1), 400},
	} {
		t.Run(test.name, func(t *testing.T) {
			e := newSyncEnv(t)
			item, id := e.captureFile("photo.heic", "image/heic", []byte("original"))
			rec := e.send("PUT", "/attachments/"+id+"/thumbnail", bytes.NewReader(test.body), "Content-Type", test.mime)
			if rec.Code != test.status {
				t.Fatalf("got %d want %d", rec.Code, test.status)
			}
			if e.item(item).Attachments[0].HasThumbnail {
				t.Fatal("invalid preview was published")
			}
		})
	}
}

func TestPreviewRequiresLiveImageOrVideoMetadata(t *testing.T) {
	e := newSyncEnv(t)
	body := jpegPreview(t, 2, 2)
	for _, mime := range []string{"text/plain", "application/pdf"} {
		_, other := e.captureFile("document", mime, []byte("original"))
		if code := e.send("PUT", "/attachments/"+other+"/thumbnail", bytes.NewReader(body), "Content-Type", "image/jpeg").Code; code != 415 {
			t.Fatalf("%s = %d", mime, code)
		}
	}
	_, id := e.captureFile("photo.heic", "image/heic", []byte("original"))
	if _, err := e.h.api.db.Exec(t.Context(), "UPDATE attachments SET deleted_at = now() WHERE id = $1", id); err != nil {
		t.Fatal(err)
	}
	if code := e.send("PUT", "/attachments/"+id+"/thumbnail", bytes.NewReader(body), "Content-Type", "image/jpeg").Code; code != 410 {
		t.Fatalf("removed = %d", code)
	}
	if code := e.send("PUT", "/attachments/00000000-0000-4000-8000-000000000001/thumbnail", bytes.NewReader(body), "Content-Type", "image/jpeg").Code; code != 404 {
		t.Fatalf("missing = %d", code)
	}
}

func TestThumbnailCapabilityCannotReadOrUploadOriginals(t *testing.T) {
	e := newSyncEnv(t)
	_, id := e.captureFile("photo.heic", "image/heic", []byte("original"))
	_, other := e.captureFile("other.heic", "image/heic", []byte("other"))
	token := thumbnailToken(t, e, id)
	for _, endpoint := range []struct{ method, path string }{
		{"PUT", "/attachments/" + id}, {"PUT", "/attachments/" + other + "/thumbnail"},
		{"GET", "/attachments/" + id + "/thumbnail"}, {"GET", "/sync/pull"},
		{"POST", "/attachments/" + id + "/thumbnail-upload-token"},
	} {
		if code := e.send(endpoint.method, endpoint.path, bytes.NewReader(jpegPreview(t, 2, 2)), "Content-Type", "image/jpeg", "Authorization", "Bearer "+token).Code; code != http.StatusUnauthorized {
			t.Fatalf("capability authorized %s: %d", endpoint.path, code)
		}
	}
	if code := e.send("PUT", "/attachments/"+id+"/thumbnail", bytes.NewReader(jpegPreview(t, 2, 2)), "Content-Type", "image/jpeg", "Authorization", "Bearer "+issuedToken(t, e, id)).Code; code != 401 {
		t.Fatalf("original capability authorized thumbnail: %d", code)
	}
	e.clock.Advance(24 * time.Hour)
	if code := e.send("PUT", "/attachments/"+id+"/thumbnail", bytes.NewReader(jpegPreview(t, 2, 2)), "Content-Type", "image/jpeg", "Authorization", "Bearer "+token).Code; code != 401 {
		t.Fatalf("expired capability = %d", code)
	}
}
