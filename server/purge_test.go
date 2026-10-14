package server

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

const day = 24 * time.Hour

func (e *syncEnv) purge() {
	e.t.Helper()
	if err := e.h.Purge(context.Background()); err != nil {
		e.t.Fatalf("purge: %v", err)
	}
}

// ageFiles makes every file in the Attachment directory look written d before the Server's now.
func (e *syncEnv) ageFiles(d time.Duration) {
	e.t.Helper()
	entries, err := os.ReadDir(e.dir)
	if err != nil {
		e.t.Fatal(err)
	}
	for _, entry := range entries {
		then := e.clock.Now().Add(-d)
		if err := os.Chtimes(filepath.Join(e.dir, entry.Name()), then, then); err != nil {
			e.t.Fatal(err)
		}
	}
}

func (e *syncEnv) files() []string {
	e.t.Helper()
	entries, err := os.ReadDir(e.dir)
	if err != nil {
		e.t.Fatal(err)
	}
	names := []string{}
	for _, entry := range entries {
		names = append(names, entry.Name())
	}
	return names
}

// pullAll follows the cursor from 0 to the end.
func (e *syncEnv) pullAll() (items map[string]pulledItem, tombstones []string, cursor int64) {
	e.t.Helper()
	items = map[string]pulledItem{}
	for {
		page := e.pull(cursor)
		for _, it := range page.Items {
			items[it.ID] = it
		}
		tombstones = append(tombstones, page.Tombstones...)
		cursor = page.Cursor
		if !page.HasMore {
			return items, tombstones, cursor
		}
	}
}

// capturePhoto captures and uploads an image, so it has a file and a thumbnail.
func (e *syncEnv) capturePhoto() (itemID, attachmentID string) {
	e.t.Helper()
	photo := pngOf(e.t, 10, 10)
	itemID, attachmentID = e.captureFile("a.png", "image/png", photo)
	if got := e.upload(attachmentID, photo); got != http.StatusNoContent {
		e.t.Fatalf("upload = %d, want 204", got)
	}
	if !e.item(itemID).Attachments[0].HasThumbnail {
		e.t.Fatal("photo has no thumbnail")
	}
	return itemID, attachmentID
}

func TestTrashIsPurgedAfter30Days(t *testing.T) {
	e := newSyncEnv(t)
	itemID, attachmentID := e.capturePhoto()
	e.push(phoneID, op{"type": "TrashItem", "at": e.at(1), "item_id": itemID})
	_, _, before := e.pullAll()

	// Devices count down to purge_at, so the purge must land on it.
	purgeAt := e.item(itemID).PurgeAt
	if want := e.clock.Now().Add(30 * day); purgeAt == nil || !purgeAt.Equal(want) {
		t.Fatalf("purge_at = %v, want %v", purgeAt, want)
	}
	e.clock.Advance(purgeAt.Sub(e.clock.Now()) - time.Minute)
	e.ageFiles(2 * day)
	e.purge()
	if items, tombstones, _ := e.pullAll(); items[itemID].ID == "" || len(tombstones) != 0 {
		t.Fatalf("a minute before 30 days: pulled %v tombstones %v, want the Item still in Trash", items, tombstones)
	}
	if len(e.files()) != 2 {
		t.Fatalf("files a minute before 30 days = %v, want the photo and its thumbnail", e.files())
	}

	e.clock.Advance(2 * time.Minute)
	e.purge()
	page := e.pull(before)
	if len(page.Items) != 0 || !slices.Equal(page.Tombstones, []string{itemID}) {
		t.Fatalf("pull after purge = %+v, want just the Item's tombstone", page)
	}
	if items, tombstones, _ := e.pullAll(); len(items) != 0 || len(tombstones) != 1 {
		t.Fatalf("pull from 0 after purge = %v %v, want no Items and one tombstone", items, tombstones)
	}
	if later := e.pull(page.Cursor); len(later.Tombstones) != 0 {
		t.Fatalf("pull from the cursor past the tombstone = %+v, want nothing", later)
	}
	for _, path := range []string{"/attachments/" + attachmentID, "/attachments/" + attachmentID + "/thumbnail"} {
		if got := e.send("GET", path, nil).Code; got != http.StatusNotFound {
			t.Errorf("GET %s after purge = %d, want 404", path, got)
		}
	}
	if files := e.files(); len(files) != 0 {
		t.Fatalf("files after purge = %v, want none", files)
	}
}

func TestTrashSyncedLateStillGets30Days(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	// Trashed offline 40 days before the phone synced.
	e.push(phoneID,
		op{"type": "CaptureItem", "at": e.at(-60 * 24 * 60), "item_id": itemID, "text": "x"},
		op{"type": "TrashItem", "at": e.at(-40 * 24 * 60), "item_id": itemID})

	e.clock.Advance(29 * day)
	e.purge()
	if items, _, _ := e.pullAll(); items[itemID].ID == "" {
		t.Fatal("Item purged 29 days after the Server learned of its Trash, want kept")
	}
}

func TestTrashedItemKeepsItsFilesUntilPurged(t *testing.T) {
	e := newSyncEnv(t)
	itemID, attachmentID := e.capturePhoto()
	e.push(phoneID, op{"type": "TrashItem", "at": e.at(1), "item_id": itemID})
	e.clock.Advance(10 * day)
	e.ageFiles(10 * day)
	e.purge()

	e.push(phoneID, op{"type": "RestoreItem", "at": e.at(2), "item_id": itemID})
	for _, path := range []string{"/attachments/" + attachmentID, "/attachments/" + attachmentID + "/thumbnail"} {
		if got := e.send("GET", path, nil).Code; got != http.StatusOK {
			t.Errorf("GET %s after restore = %d, want 200", path, got)
		}
	}
}

func TestRemovedAttachmentFilesAreDeleted(t *testing.T) {
	e := newSyncEnv(t)
	photo := pngOf(t, 10, 10)
	itemID, removedID, keptID := uuid.NewString(), uuid.NewString(), uuid.NewString()
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "x", "attachments": []any{
		map[string]any{"id": removedID, "filename": "a.png", "mime_type": "image/png", "size_bytes": len(photo)},
		map[string]any{"id": keptID, "filename": "b.png", "mime_type": "image/png", "size_bytes": len(photo)},
	}})
	e.upload(removedID, photo)
	e.upload(keptID, photo)
	e.push(phoneID, op{"type": "RemoveAttachment", "at": e.at(1), "item_id": itemID, "attachment_id": removedID})

	e.ageFiles(2 * day)
	e.purge()
	if files := e.files(); len(files) != 2 || !slices.Contains(files, keptID) {
		t.Fatalf("files = %v, want only the kept photo and its thumbnail", files)
	}
	for _, path := range []string{"/attachments/" + keptID, "/attachments/" + keptID + "/thumbnail"} {
		if got := e.send("GET", path, nil).Code; got != http.StatusOK {
			t.Errorf("GET %s = %d, want 200", path, got)
		}
	}
}

func TestLeftoverFilesAreDeletedAfterADay(t *testing.T) {
	e := newSyncEnv(t)
	write := func(name string) {
		if err := os.WriteFile(filepath.Join(e.dir, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	crashed, unknown := uuid.NewString()+".partial-ABC", uuid.NewString()
	write(crashed)
	write(unknown)
	// Not names the Server makes, so a mistyped directory setting can't get them deleted.
	write("tax-return.pdf")
	write(uuid.NewString() + ".pdf")
	write("{" + uuid.NewString() + "}")
	if err := os.Mkdir(filepath.Join(e.dir, uuid.NewString()), 0o700); err != nil {
		t.Fatal(err)
	}
	notMine := len(e.files()) - 2

	e.ageFiles(day - time.Minute)
	e.purge()
	if got := len(e.files()); got != notMine+2 {
		t.Fatalf("files under a day old = %v, want all kept (an upload may be in progress)", e.files())
	}

	e.ageFiles(day + time.Minute)
	e.purge()
	files := e.files()
	if len(files) != notMine || slices.Contains(files, crashed) || slices.Contains(files, unknown) {
		t.Fatalf("files over a day old = %v, want only the ones the Server didn't name", files)
	}
}

func TestPurgedItemIDCannotBeCapturedAgain(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "x"},
		op{"type": "TrashItem", "at": e.at(1), "item_id": itemID})
	e.clock.Advance(31 * day)
	e.purge()
	if _, tombstones, _ := e.pullAll(); len(tombstones) != 1 {
		t.Fatalf("tombstones = %v, want the purged Item", tombstones)
	}

	res := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(2), "item_id": itemID, "text": "x"})
	if res[0].Status != "rejected" || res[0].Reason != "exists" {
		t.Fatalf("recapture of a purged id = %+v, want rejected exists", res[0])
	}
}

func TestAppliedOpsAreForgottenAfter90Days(t *testing.T) {
	e := newSyncEnv(t)
	capture := op{"type": "CaptureItem", "at": e.at(0), "item_id": uuid.NewString(), "text": "x"}
	e.push(phoneID, capture)

	e.clock.Advance(90*day - time.Minute)
	e.purge()
	if res := e.push(phoneID, capture); res[0].Status != "accepted" {
		t.Fatalf("replay before 90 days = %+v, want the first result", res[0])
	}

	e.clock.Advance(2 * time.Minute)
	e.purge()
	if res := e.push(phoneID, capture); res[0].Reason != "exists" {
		t.Fatalf("replay after 90 days = %+v, want applied afresh and rejected exists", res[0])
	}
}

func TestPullPagesThroughTombstones(t *testing.T) {
	e := newSyncEnv(t)
	var captures, trashes []op
	want := map[string]bool{}
	for i := range 700 {
		id := uuid.NewString()
		want[id] = true
		captures = append(captures, op{"type": "CaptureItem", "at": e.at(0), "item_id": id, "text": "x"})
		if i%2 == 0 {
			trashes = append(trashes, op{"type": "TrashItem", "at": e.at(1), "item_id": id})
		}
	}
	e.push(phoneID, captures[:500]...)
	e.push(phoneID, captures[500:]...)
	e.push(phoneID, trashes...)
	e.clock.Advance(31 * day)
	e.purge()
	// A change after the tombstones, so they sit mid-stream.
	lateID := uuid.NewString()
	want[lateID] = true
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(2), "item_id": lateID, "text": "x"})

	seen := map[string]int{}
	pages, tombstones := 0, 0
	for cursor := int64(0); ; {
		page := e.pull(cursor)
		pages++
		tombstones += len(page.Tombstones)
		if n := len(page.Items) + len(page.Tombstones); n > 500 {
			t.Fatalf("page %d has %d changes, want at most 500", pages, n)
		}
		for _, it := range page.Items {
			seen[it.ID]++
		}
		for _, id := range page.Tombstones {
			seen[id]++
		}
		if !page.HasMore {
			break
		}
		cursor = page.Cursor
	}
	if pages != 2 || len(seen) != len(want) || tombstones != len(trashes) {
		t.Fatalf("pulled %d distinct changes (%d tombstones) in %d pages, want %d (%d) in 2",
			len(seen), tombstones, pages, len(want), len(trashes))
	}
	for id, n := range seen {
		if !want[id] || n != 1 {
			t.Fatalf("change %s pulled %d times", id, n)
		}
	}
}

func TestPurgeDuringPushesNeverSkipsAPullingDevice(t *testing.T) {
	e := newSyncEnv(t)
	const trashed, devices, pushesEach = 2000, 10, 20

	var captures, trashes []op
	for range trashed {
		id := uuid.NewString()
		captures = append(captures, op{"type": "CaptureItem", "at": e.at(0), "item_id": id, "text": "x"})
		trashes = append(trashes, op{"type": "TrashItem", "at": e.at(1), "item_id": id})
	}
	for i := 0; i < trashed; i += 500 {
		e.push(phoneID, captures[i:i+500]...)
		e.push(phoneID, trashes[i:i+500]...)
	}
	_, _, cursor := e.pullAll()
	e.clock.Advance(31 * day)

	seen := map[string]bool{}
	pullOnce := func() bool {
		rec := e.do("GET", fmt.Sprintf("/sync/pull?cursor=%d", cursor), nil)
		var page pullPage
		if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &page) != nil {
			t.Errorf("pull = %d %s", rec.Code, rec.Body)
			return false
		}
		for _, id := range page.Tombstones {
			seen[id] = true
		}
		cursor = page.Cursor
		return page.HasMore
	}

	var writers sync.WaitGroup
	writers.Go(func() {
		if err := e.h.Purge(context.Background()); err != nil {
			t.Errorf("purge: %v", err)
		}
	})
	for d := range devices {
		writers.Go(func() {
			device := fmt.Sprintf("00000000-0000-4000-8000-%012d", d+10)
			for range pushesEach {
				body, _ := json.Marshal(map[string]any{"device_id": device, "ops": []op{
					{"id": uuid.NewString(), "type": "CaptureItem", "at": e.at(2), "item_id": uuid.NewString(), "text": "x"},
				}})
				if rec := e.do("POST", "/sync/push", body); rec.Code != http.StatusOK {
					t.Errorf("push = %d %s", rec.Code, rec.Body)
				}
			}
		})
	}
	done := make(chan struct{})
	go func() { writers.Wait(); close(done) }()
	for pulling := true; pulling; {
		select {
		case <-done:
			pulling = false
		default:
			pullOnce()
		}
	}
	for pullOnce() {
	}

	if len(seen) != trashed {
		t.Fatalf("puller saw %d of %d tombstones", len(seen), trashed)
	}
}
