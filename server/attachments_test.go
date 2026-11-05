package server

import (
	"bytes"
	"context"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func (e *syncEnv) send(method, path string, body io.Reader, header ...string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, body)
	req.RemoteAddr = "203.0.113.1:5000"
	req.Header.Set("Authorization", "Bearer "+testSecret)
	for i := 0; i+1 < len(header); i += 2 {
		req.Header.Set(header[i], header[i+1])
	}
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	return rec
}

// captureFile pushes an Item with one Attachment whose metadata matches content, and returns the Attachment id.
func (e *syncEnv) captureFile(name, mimeType string, content []byte) (itemID, attachmentID string) {
	e.t.Helper()
	itemID, attachmentID = uuid.NewString(), uuid.NewString()
	res := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "attachments": []any{
		map[string]any{"id": attachmentID, "filename": name, "mime_type": mimeType, "size_bytes": len(content)},
	}})
	if res[0].Status != "accepted" {
		e.t.Fatalf("capture = %+v, want accepted", res[0])
	}
	return itemID, attachmentID
}

func (e *syncEnv) upload(attachmentID string, content []byte) int {
	return e.send("PUT", "/attachments/"+attachmentID, bytes.NewReader(content)).Code
}

func pngOf(t *testing.T, w, h int) []byte {
	t.Helper()
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for y := range h {
		for x := range w {
			img.Set(x, y, color.RGBA{uint8(x), uint8(y), 128, 255})
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func thumbnailSize(t *testing.T, rec *httptest.ResponseRecorder) image.Point {
	t.Helper()
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "image/jpeg" {
		t.Fatalf("thumbnail = %d %q, want 200 image/jpeg", rec.Code, rec.Header().Get("Content-Type"))
	}
	img, err := jpeg.Decode(rec.Body)
	if err != nil {
		t.Fatalf("thumbnail is not a JPEG: %v", err)
	}
	return img.Bounds().Size()
}

func TestUploadedFileDownloadsOnAnotherDevice(t *testing.T) {
	e := newSyncEnv(t)
	content := []byte("%PDF-1.7 pretend this is a lease")
	itemID, id := e.captureFile("lease.pdf", "application/pdf", content)

	if got := e.item(itemID).Attachments[0]; got.Uploaded {
		t.Fatalf("attachment before upload = %+v, want uploaded false", got)
	}
	if got := e.send("GET", "/attachments/"+id, nil).Code; got != http.StatusNotFound {
		t.Fatalf("download before upload = %d, want 404", got)
	}
	cursor := e.pull(0).Cursor

	if got := e.upload(id, content); got != http.StatusNoContent {
		t.Fatalf("upload = %d, want 204", got)
	}

	// The upload is a change, so a Device that already pulled the Item learns the file is ready.
	page := e.pull(cursor)
	if len(page.Items) != 1 || !page.Items[0].Attachments[0].Uploaded {
		t.Fatalf("pull after upload = %+v, want the Item with its Attachment uploaded", page.Items)
	}
	rec := e.send("GET", "/attachments/"+id, nil)
	if rec.Code != http.StatusOK || !bytes.Equal(rec.Body.Bytes(), content) {
		t.Fatalf("download = %d %q, want 200 and the uploaded bytes", rec.Code, rec.Body)
	}
	h := rec.Header()
	if h.Get("Content-Type") != "application/pdf" || h.Get("X-Content-Type-Options") != "nosniff" ||
		h.Get("Content-Disposition") != `attachment; filename=lease.pdf` {
		t.Fatalf("download headers = %v, want the declared type, nosniff and an attachment disposition", h)
	}
}

func TestDownloadServesByteRanges(t *testing.T) {
	e := newSyncEnv(t)
	content := []byte("0123456789")
	_, id := e.captureFile("digits.txt", "text/plain", content)
	e.upload(id, content)

	rec := e.send("GET", "/attachments/"+id, nil, "Range", "bytes=2-5")
	if rec.Code != http.StatusPartialContent || rec.Body.String() != "2345" {
		t.Fatalf("range download = %d %q, want 206 \"2345\"", rec.Code, rec.Body)
	}
}

func TestReuploadAfterSuccessChangesNothing(t *testing.T) {
	e := newSyncEnv(t)
	content := []byte("hello")
	_, id := e.captureFile("a.txt", "text/plain", content)
	e.upload(id, content)
	cursor := e.pull(0).Cursor

	// The phone never saw the response, so it uploads again.
	if got := e.upload(id, content); got != http.StatusNoContent {
		t.Fatalf("re-upload = %d, want 204", got)
	}
	if page := e.pull(cursor); len(page.Items) != 0 {
		t.Fatalf("pull after re-upload = %+v, want no changes", page.Items)
	}
	if rec := e.send("GET", "/attachments/"+id, nil); rec.Body.String() != "hello" {
		t.Fatalf("download after re-upload = %q, want hello", rec.Body)
	}
}

func TestUploadMustMatchTheDeclaredSize(t *testing.T) {
	e := newSyncEnv(t)
	itemID, id := e.captureFile("a.txt", "text/plain", []byte("12345"))

	for _, body := range []string{"1234", "123456"} {
		if got := e.upload(id, []byte(body)); got != http.StatusBadRequest {
			t.Errorf("upload of %d bytes for a 5-byte Attachment = %d, want 400", len(body), got)
		}
	}
	if e.item(itemID).Attachments[0].Uploaded {
		t.Fatal("attachment marked uploaded after mismatched uploads")
	}
	if got := e.send("GET", "/attachments/"+id, nil).Code; got != http.StatusNotFound {
		t.Fatalf("download after mismatched uploads = %d, want 404", got)
	}
	if got := e.upload(id, []byte("12345")); got != http.StatusNoContent {
		t.Fatalf("upload of the right size = %d, want 204", got)
	}
}

func TestEmptyFileUploads(t *testing.T) {
	e := newSyncEnv(t)
	_, id := e.captureFile("empty.txt", "text/plain", nil)
	if got := e.upload(id, nil); got != http.StatusNoContent {
		t.Fatalf("upload of empty file = %d, want 204", got)
	}
	if rec := e.send("GET", "/attachments/"+id, nil); rec.Code != http.StatusOK || rec.Body.Len() != 0 {
		t.Fatalf("download of empty file = %d %q, want 200 and no bytes", rec.Code, rec.Body)
	}
}

func TestUploadBeforeMetadataIsNotFound(t *testing.T) {
	e := newSyncEnv(t)
	if got := e.upload(uuid.NewString(), []byte("x")); got != http.StatusNotFound {
		t.Fatalf("upload with no pushed metadata = %d, want 404", got)
	}
	if got := e.upload("not-a-uuid", []byte("x")); got != http.StatusNotFound {
		t.Fatalf("upload to a malformed id = %d, want 404", got)
	}
}

func TestRemovedAttachmentIsGone(t *testing.T) {
	e := newSyncEnv(t)
	photo, notes := pngOf(t, 10, 10), []byte("x")
	itemID, uploadedID, pendingID := uuid.NewString(), uuid.NewString(), uuid.NewString()
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "keep the Item", "attachments": []any{
		map[string]any{"id": uploadedID, "filename": "a.png", "mime_type": "image/png", "size_bytes": len(photo)},
		map[string]any{"id": pendingID, "filename": "b.txt", "mime_type": "text/plain", "size_bytes": len(notes)},
	}})
	e.upload(uploadedID, photo)
	e.push(phoneID,
		op{"type": "RemoveAttachment", "at": e.at(1), "item_id": itemID, "attachment_id": uploadedID},
		op{"type": "RemoveAttachment", "at": e.at(1), "item_id": itemID, "attachment_id": pendingID})

	for _, path := range []string{"/attachments/" + uploadedID, "/attachments/" + uploadedID + "/thumbnail"} {
		if got := e.send("GET", path, nil).Code; got != http.StatusNotFound {
			t.Errorf("GET %s after removal = %d, want 404", path, got)
		}
	}
	if got := e.upload(pendingID, notes); got != http.StatusGone {
		t.Errorf("upload after removal = %d, want 410", got)
	}
}

func TestImageUploadGetsAThumbnail(t *testing.T) {
	e := newSyncEnv(t)
	content := pngOf(t, 1000, 500)
	itemID, id := e.captureFile("wide.png", "image/png", content)
	e.upload(id, content)

	if got := e.item(itemID).Attachments[0]; !got.HasThumbnail {
		t.Fatalf("attachment = %+v, want has_thumbnail", got)
	}
	if got := thumbnailSize(t, e.send("GET", "/attachments/"+id+"/thumbnail", nil)); got != image.Pt(thumbnailEdgePixels, thumbnailEdgePixels/2) {
		t.Fatalf("thumbnail size = %v, want long edge %d keeping the aspect ratio", got, thumbnailEdgePixels)
	}
}

func TestSmallImageIsNotEnlarged(t *testing.T) {
	e := newSyncEnv(t)
	content := pngOf(t, 40, 30)
	_, id := e.captureFile("tiny.png", "image/png", content)
	e.upload(id, content)

	if got := thumbnailSize(t, e.send("GET", "/attachments/"+id+"/thumbnail", nil)); got != image.Pt(40, 30) {
		t.Fatalf("thumbnail size = %v, want 40x30", got)
	}
}

// withOrientation inserts an EXIF block whose Orientation tag is o right after the JPEG's start marker.
func withOrientation(jpg []byte, order binary.AppendByteOrder, o uint16) []byte {
	tiff := []byte("MM\x00\x2a")
	if order == binary.LittleEndian {
		tiff = []byte("II\x2a\x00")
	}
	tiff = order.AppendUint32(tiff, 8) // IFD0 right after this header
	tiff = order.AppendUint16(tiff, 1) // one entry
	tiff = order.AppendUint16(tiff, 0x0112)
	tiff = order.AppendUint16(tiff, 3) // SHORT
	tiff = order.AppendUint32(tiff, 1)
	tiff = order.AppendUint16(tiff, o)
	tiff = append(tiff, 0, 0, 0, 0, 0, 0) // value padding, then no next IFD
	payload := append([]byte("Exif\x00\x00"), tiff...)

	seg := []byte{0xFF, 0xE1}
	seg = binary.BigEndian.AppendUint16(seg, uint16(len(payload)+2))
	seg = append(seg, payload...)
	return append(append(append([]byte{}, jpg[:2]...), seg...), jpg[2:]...)
}

func TestExifOrientationReadsBothByteOrders(t *testing.T) {
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, image.NewGray(image.Rect(0, 0, 8, 8)), nil); err != nil {
		t.Fatal(err)
	}
	if got := exifOrientation(bytes.NewReader(buf.Bytes())); got != 1 {
		t.Errorf("orientation without EXIF = %d, want 1", got)
	}
	for _, order := range []binary.AppendByteOrder{binary.BigEndian, binary.LittleEndian} {
		if got := exifOrientation(bytes.NewReader(withOrientation(buf.Bytes(), order, 8))); got != 8 {
			t.Errorf("%v orientation = %d, want 8", order, got)
		}
	}
}

// Each EXIF orientation says which visual edge the stored first row runs along, and in which direction.
func TestOrientPutsTheFirstRowWhereEXIFSays(t *testing.T) {
	red, green := color.RGBA{255, 0, 0, 255}, color.RGBA{0, 255, 0, 255}
	stored := image.NewRGBA(image.Rect(0, 0, 4, 2))
	stored.SetRGBA(0, 0, red)
	stored.SetRGBA(1, 0, green)

	want := map[int][2]image.Point{ // where red and green end up
		1: {{0, 0}, {1, 0}},
		2: {{3, 0}, {2, 0}}, // mirrored
		3: {{3, 1}, {2, 1}}, // turned 180°
		4: {{0, 1}, {1, 1}}, // flipped
		5: {{0, 0}, {0, 1}}, // first row down the left
		6: {{1, 0}, {1, 1}}, // first row down the right: turn clockwise
		7: {{1, 3}, {1, 2}}, // first row up the right
		8: {{0, 3}, {0, 2}}, // first row up the left: turn counter-clockwise
	}
	for o, at := range want {
		got := orient(stored, o)
		if got.RGBAAt(at[0].X, at[0].Y) != red || got.RGBAAt(at[1].X, at[1].Y) != green {
			t.Errorf("orientation %d: red at %v and green at %v not found in %v", o, at[0], at[1], got.Pix)
		}
	}
}

func TestSidewaysPhotoThumbnailIsUpright(t *testing.T) {
	e := newSyncEnv(t)
	var buf bytes.Buffer
	if err := jpeg.Encode(&buf, image.NewGray(image.Rect(0, 0, 800, 400)), nil); err != nil {
		t.Fatal(err)
	}
	// Orientation 6: the camera stored a portrait photo sideways and asks viewers to turn it 90° clockwise.
	content := withOrientation(buf.Bytes(), binary.BigEndian, 6)
	_, id := e.captureFile("portrait.jpg", "image/jpeg", content)
	e.upload(id, content)

	if got := thumbnailSize(t, e.send("GET", "/attachments/"+id+"/thumbnail", nil)); got != image.Pt(thumbnailEdgePixels/2, thumbnailEdgePixels) {
		t.Fatalf("thumbnail size = %v, want portrait %dx%d", got, thumbnailEdgePixels/2, thumbnailEdgePixels)
	}
}

func TestNonImageHasNoThumbnail(t *testing.T) {
	e := newSyncEnv(t)
	content := []byte("not an image")
	itemID, id := e.captureFile("photo.png", "image/png", content)
	if got := e.upload(id, content); got != http.StatusNoContent {
		t.Fatalf("upload = %d, want 204", got)
	}
	if got := e.item(itemID).Attachments[0]; !got.Uploaded || got.HasThumbnail {
		t.Fatalf("attachment = %+v, want uploaded without a thumbnail", got)
	}
	if got := e.send("GET", "/attachments/"+id+"/thumbnail", nil).Code; got != http.StatusNotFound {
		t.Fatalf("thumbnail = %d, want 404", got)
	}
}

// Decoding needs memory for every pixel, so an image past the limit gets no thumbnail even if it is valid.
func TestImageOverThePixelLimitGetsNoThumbnail(t *testing.T) {
	e := newSyncEnv(t)
	var buf bytes.Buffer
	if err := png.Encode(&buf, image.NewGray(image.Rect(0, 0, 8193, maxThumbnailSourcePixels/8192))); err != nil {
		t.Fatal(err)
	}
	content := buf.Bytes()
	itemID, id := e.captureFile("huge.png", "image/png", content)
	if got := e.upload(id, content); got != http.StatusNoContent {
		t.Fatalf("upload = %d, want 204", got)
	}
	if e.item(itemID).Attachments[0].HasThumbnail {
		t.Fatal("thumbnail made for an image over the pixel limit")
	}
}

func TestAttachmentsNeedTheSecret(t *testing.T) {
	e := newSyncEnv(t)
	for _, method := range []string{"PUT", "GET"} {
		if got := request(e.h, method, "/attachments/"+uuid.NewString(), "203.0.113.1:5000", ""); got != http.StatusUnauthorized {
			t.Errorf("%s /attachments without secret = %d, want 401", method, got)
		}
	}
}

func TestStoreKeepsKeysInsideItsDirectory(t *testing.T) {
	parent := t.TempDir()
	dir := filepath.Join(parent, "attachments")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	store, err := openAttachmentStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{"../escaped", "/tmp/escaped", "sub/../../escaped"} {
		if err := store.Put(key, strings.NewReader("x"), 1); err == nil {
			t.Errorf("Put(%q) succeeded, want error", key)
		}
		if f, err := store.Open(key); err == nil {
			f.Close()
			t.Errorf("Open(%q) succeeded, want error", key)
		}
	}
	if _, err := os.Stat(filepath.Join(parent, "escaped")); err == nil {
		t.Fatal("a file was written outside the store's directory")
	}
}

func TestFailedPutLeavesNoFile(t *testing.T) {
	dir := t.TempDir()
	store, err := openAttachmentStore(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := store.Put("key", strings.NewReader("1234"), 5); err != errSizeMismatch {
		t.Fatalf("Put of 4 bytes declared as 5 = %v, want errSizeMismatch", err)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Fatalf("directory after failed Put holds %v, want nothing", entries)
	}
}

func TestMissingOriginalQueuesRecoveryAndValidatesReplacement(t *testing.T) {
	e := newSyncEnv(t)
	content := []byte("original bytes")
	_, id := e.captureFile("file.txt", "text/plain", content)
	if got := e.upload(id, content); got != 204 {
		t.Fatal(got)
	}
	cursor := e.pull(0).Cursor
	if err := os.Remove(filepath.Join(e.dir, id)); err != nil {
		t.Fatal(err)
	}
	if got := e.send("GET", "/attachments/"+id, nil).Code; got != 500 {
		t.Fatalf("GET = %d", got)
	}
	page := e.pull(cursor)
	if len(page.Items) != 1 || page.Items[0].Attachments[0].Uploaded {
		t.Fatalf("missing original not queued: %+v", page.Items)
	}
	if got := e.upload(id, []byte("short")); got != 400 {
		t.Fatalf("wrong-size repair = %d", got)
	}
	if got := e.upload(id, content); got != 204 {
		t.Fatalf("repair = %d", got)
	}
	rec := e.send("GET", "/attachments/"+id, nil)
	if rec.Code != 200 || !bytes.Equal(rec.Body.Bytes(), content) {
		t.Fatalf("repaired GET = %d %q", rec.Code, rec.Body)
	}
	page = e.pull(page.Cursor)
	if len(page.Items) != 1 || !page.Items[0].Attachments[0].Uploaded {
		t.Fatalf("repair not published: %+v", page.Items)
	}
}

func TestRetryRepairsMissingOriginalWithoutConfirmingInvalidBody(t *testing.T) {
	for _, content := range [][]byte{nil, []byte("original")} {
		e := newSyncEnv(t)
		itemID, id := e.captureFile("file", "application/octet-stream", content)
		if got := e.upload(id, content); got != 204 {
			t.Fatal(got)
		}
		if err := os.Remove(filepath.Join(e.dir, id)); err != nil {
			t.Fatal(err)
		}
		if got := e.upload(id, append(content, 'x')); got != 400 {
			t.Fatalf("invalid repair = %d", got)
		}
		if e.item(itemID).Attachments[0].Uploaded {
			t.Fatal("invalid body confirmed missing file")
		}
		if got := e.upload(id, content); got != 204 {
			t.Fatalf("valid repair = %d", got)
		}
		if got := e.send("GET", "/attachments/"+id, nil); got.Code != 200 || !bytes.Equal(got.Body.Bytes(), content) {
			t.Fatalf("GET = %d %q", got.Code, got.Body)
		}
	}
}

func TestMissingThumbnailDoesNotMakeOriginalUnavailable(t *testing.T) {
	e := newSyncEnv(t)
	_, id := e.capturePhoto()
	var key string
	if err := e.h.api.db.QueryRow(context.Background(), "SELECT thumbnail_key FROM attachments WHERE id = $1", id).Scan(&key); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(e.dir, key)); err != nil {
		t.Fatal(err)
	}
	if got := e.send("GET", "/attachments/"+id+"/thumbnail", nil).Code; got != http.StatusInternalServerError {
		t.Fatalf("missing thumbnail = %d, want 500", got)
	}
	if got := e.send("GET", "/attachments/"+id, nil).Code; got != http.StatusOK {
		t.Fatalf("original = %d, want 200", got)
	}
}

func TestMissingThumbnailCanBeUploadedAgain(t *testing.T) {
	e := newSyncEnv(t)
	_, id := e.capturePhoto()
	var key string
	if err := e.h.api.db.QueryRow(context.Background(), "SELECT thumbnail_key FROM attachments WHERE id = $1", id).Scan(&key); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(e.dir, key)); err != nil {
		t.Fatal(err)
	}
	cursor := e.pull(0).Cursor
	if got := e.send("GET", "/attachments/"+id+"/thumbnail", nil).Code; got != 500 {
		t.Fatal(got)
	}
	page := e.pull(cursor)
	if len(page.Items) != 1 || page.Items[0].Attachments[0].HasThumbnail || !page.Items[0].Attachments[0].Uploaded {
		t.Fatalf("preview loss not published: %+v", page.Items)
	}
	if got := e.send("PUT", "/attachments/"+id+"/thumbnail", bytes.NewReader(jpegPreview(t, 40, 30)), "Content-Type", "image/jpeg").Code; got != 204 {
		t.Fatal(got)
	}
	if got := thumbnailSize(t, e.send("GET", "/attachments/"+id+"/thumbnail", nil)); got != image.Pt(40, 30) {
		t.Fatal(got)
	}
}

func TestStorageErrorsDoNotQueueRecovery(t *testing.T) {
	e := newSyncEnv(t)
	_, id := e.capturePhoto()
	cursor := e.pull(0).Cursor
	if err := os.Remove(filepath.Join(e.dir, id)); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(id, filepath.Join(e.dir, id)); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{"GET", "PUT"} {
		if got := e.send(method, "/attachments/"+id, strings.NewReader("body")).Code; got != 500 {
			t.Fatalf("%s = %d", method, got)
		}
	}
	if page := e.pull(cursor); len(page.Items) != 0 {
		t.Fatalf("storage error changed sync state: %+v", page.Items)
	}
}

func TestMissingOriginalAndThumbnailAreBothRecovered(t *testing.T) {
	e := newSyncEnv(t)
	content := pngOf(t, 10, 10)
	_, id := e.captureFile("photo.png", "image/png", content)
	if got := e.upload(id, content); got != 204 {
		t.Fatal(got)
	}
	var key string
	if err := e.h.api.db.QueryRow(context.Background(), "SELECT thumbnail_key FROM attachments WHERE id = $1", id).Scan(&key); err != nil {
		t.Fatal(err)
	}
	for _, key := range []string{id, key} {
		if err := os.Remove(filepath.Join(e.dir, key)); err != nil {
			t.Fatal(err)
		}
	}
	e.send("GET", "/attachments/"+id+"/thumbnail", nil)
	e.send("GET", "/attachments/"+id, nil)
	cursor := e.pull(0).Cursor
	e.send("GET", "/attachments/"+id, nil)
	if page := e.pull(cursor); len(page.Items) != 0 {
		t.Fatal("repeated failure bumped sync cursor")
	}
	if got := e.upload(id, content); got != 204 {
		t.Fatal(got)
	}
	if got := thumbnailSize(t, e.send("GET", "/attachments/"+id+"/thumbnail", nil)); got != image.Pt(10, 10) {
		t.Fatal(got)
	}
}

func TestRetryRepairsMissingThumbnailWithoutDownloadFirst(t *testing.T) {
	e := newSyncEnv(t)
	_, id := e.capturePhoto()
	var key string
	if err := e.h.api.db.QueryRow(context.Background(), "SELECT thumbnail_key FROM attachments WHERE id = $1", id).Scan(&key); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(e.dir, key)); err != nil {
		t.Fatal(err)
	}
	if got := e.send("PUT", "/attachments/"+id+"/thumbnail", bytes.NewReader(jpegPreview(t, 40, 30)), "Content-Type", "image/jpeg").Code; got != 204 {
		t.Fatal(got)
	}
	if got := thumbnailSize(t, e.send("GET", "/attachments/"+id+"/thumbnail", nil)); got != image.Pt(40, 30) {
		t.Fatal(got)
	}
}

func TestStaleMissingFileRequestCannotInvalidateCompletedRepair(t *testing.T) {
	for _, original := range []bool{true, false} {
		t.Run(map[bool]string{true: "original", false: "thumbnail"}[original], func(t *testing.T) {
			e := newSyncEnv(t)
			_, id := e.capturePhoto()
			key := id
			if !original {
				if err := e.h.api.db.QueryRow(context.Background(), "SELECT thumbnail_key FROM attachments WHERE id = $1", id).Scan(&key); err != nil {
					t.Fatal(err)
				}
			}
			if err := os.Remove(filepath.Join(e.dir, key)); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			tx, err := e.h.api.db.Begin(ctx)
			if err != nil {
				t.Fatal(err)
			}
			defer tx.Rollback(context.Background())
			if _, err := tx.Exec(ctx, "SELECT pg_advisory_xact_lock($1)", syncLock); err != nil {
				t.Fatal(err)
			}
			result := make(chan error, 1)
			go func() { _, err := e.h.api.invalidateMissingFile(ctx, key, original); result <- err }()
			for {
				var waiting bool
				if err := e.h.api.db.QueryRow(ctx, "SELECT EXISTS(SELECT 1 FROM pg_stat_activity WHERE datname = current_database() AND wait_event = 'advisory')").Scan(&waiting); err != nil {
					t.Fatal(err)
				}
				if waiting {
					break
				}
				select {
				case err := <-result:
					t.Fatalf("did not wait for publication: %v", err)
				case <-ctx.Done():
					t.Fatal(ctx.Err())
				case <-time.After(time.Millisecond):
				}
			}
			if original {
				if err := e.h.api.files.Put(key, strings.NewReader("restored"), 8); err != nil {
					t.Fatal(err)
				}
			} else {
				newKey := uuid.NewString()
				if err := e.h.api.files.Put(newKey, strings.NewReader("restored"), 8); err != nil {
					t.Fatal(err)
				}
				if _, err := tx.Exec(ctx, "UPDATE attachments SET thumbnail_key = $1 WHERE id = $2", newKey, id); err != nil {
					t.Fatal(err)
				}
			}
			cursor := e.pull(0).Cursor
			if err := tx.Commit(ctx); err != nil {
				t.Fatal(err)
			}
			if err := <-result; err != nil {
				t.Fatal(err)
			}
			if page := e.pull(cursor); len(page.Items) != 0 {
				t.Fatalf("stale request invalidated repaired file: %+v", page.Items)
			}
			got := e.item(e.pull(0).Items[0].ID).Attachments[0]
			if !got.Uploaded || !got.HasThumbnail {
				t.Fatalf("repair flags lost: %+v", got)
			}
		})
	}
}

func TestMissingFileCannotRepublishRemovedAttachment(t *testing.T) {
	e := newSyncEnv(t)
	itemID, id := e.capturePhoto()
	if err := os.Remove(filepath.Join(e.dir, id)); err != nil {
		t.Fatal(err)
	}
	e.push(phoneID, op{"type": "RemoveAttachment", "at": e.at(1), "item_id": itemID, "attachment_id": id})
	cursor := e.pull(0).Cursor
	if _, err := e.h.api.invalidateMissingFile(context.Background(), id, true); err != nil {
		t.Fatal(err)
	}
	if got := e.upload(id, pngOf(t, 10, 10)); got != 410 {
		t.Fatal(got)
	}
	if page := e.pull(cursor); len(page.Items) != 0 {
		t.Fatal("removed Attachment changed during recovery")
	}
}
