package server

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5/pgconn"
)

// Device ids are fixed so tie-breaks are predictable: phone < desktop.
const (
	phoneID   = "00000000-0000-4000-8000-000000000001"
	desktopID = "00000000-0000-4000-8000-000000000002"
)

type syncEnv struct {
	t     *testing.T
	h     *Server
	clock *testClock
	dir   string // the Attachment directory
}

func newSyncEnv(t *testing.T) *syncEnv {
	t.Helper()
	db := openPool(t, newTestDatabase(t))
	if err := Migrate(context.Background(), db); err != nil {
		t.Fatal(err)
	}
	// A day after at(0), so tests' Device timestamps are in the past unless a test means otherwise.
	clock := &testClock{now: syncBase.Add(24 * time.Hour)}
	dir := t.TempDir()
	h, err := New(Config{Secret: testSecret, Now: clock.Now, DB: db, AttachmentDir: dir})
	if err != nil {
		t.Fatal(err)
	}
	return &syncEnv{t: t, h: h, clock: clock, dir: dir}
}

var syncBase = time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)

// at is a Device timestamp minutes after syncBase.
func (e *syncEnv) at(minutes int) string {
	return syncBase.Add(time.Duration(minutes) * time.Minute).Format(time.RFC3339Nano)
}

type op map[string]any

type pushResult struct {
	OpID   string  `json:"op_id"`
	Status string  `json:"status"`
	Reason string  `json:"reason"`
	Text   *string `json:"text"`
}

type pulledAttachment struct {
	ID           string `json:"id"`
	Filename     string `json:"filename"`
	MimeType     string `json:"mime_type"`
	SizeBytes    int64  `json:"size_bytes"`
	Uploaded     bool   `json:"uploaded"`
	HasThumbnail bool   `json:"has_thumbnail"`
}

type pulledItem struct {
	ID          string             `json:"id"`
	TopicID     *string            `json:"topic_id"`
	Tunnel      bool               `json:"tunnel"`
	Text        *string            `json:"text"`
	TextRev     int64              `json:"text_rev"`
	CaptureTime time.Time          `json:"capture_time"`
	DeletedAt   *time.Time         `json:"deleted_at"`
	PurgeAt     *time.Time         `json:"purge_at"`
	Attachments []pulledAttachment `json:"attachments"`
}

type pulledTopic struct {
	ActivityAt time.Time  `json:"activity_at"`
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	DeletedAt  *time.Time `json:"deleted_at"`
}

type pullPage struct {
	Items      []pulledItem  `json:"items"`
	Topics     []pulledTopic `json:"topics"`
	Tombstones []string      `json:"tombstones"` // ids of purged Items
	Cursor     int64         `json:"cursor"`
	HasMore    bool          `json:"has_more"`
	Settings   struct {
		TrashAfterCopy *bool `json:"trash_after_copy"`
	} `json:"settings"`
}

func (e *syncEnv) do(method, path string, body []byte) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, bytes.NewReader(body))
	req.RemoteAddr = "203.0.113.1:5000"
	req.Header.Set("Authorization", "Bearer "+testSecret)
	rec := httptest.NewRecorder()
	e.h.ServeHTTP(rec, req)
	return rec
}

// push sends ops from device, giving each an id if it has none, and returns one result per op.
func (e *syncEnv) push(device string, ops ...op) []pushResult {
	e.t.Helper()
	for _, o := range ops {
		if _, ok := o["id"]; !ok {
			o["id"] = uuid.NewString()
		}
	}
	body, _ := json.Marshal(map[string]any{"device_id": device, "ops": ops})
	rec := e.do("POST", "/sync/push", body)
	if rec.Code != http.StatusOK {
		e.t.Fatalf("push = %d %s", rec.Code, rec.Body)
	}
	var resp struct{ Results []pushResult }
	if err := json.Unmarshal(rec.Body.Bytes(), &resp); err != nil {
		e.t.Fatal(err)
	}
	if len(resp.Results) != len(ops) {
		e.t.Fatalf("push returned %d results for %d ops", len(resp.Results), len(ops))
	}
	return resp.Results
}

func (e *syncEnv) pull(cursor int64) pullPage {
	e.t.Helper()
	rec := e.do("GET", fmt.Sprintf("/sync/pull?cursor=%d", cursor), nil)
	if rec.Code != http.StatusOK {
		e.t.Fatalf("pull = %d %s", rec.Code, rec.Body)
	}
	var page pullPage
	if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
		e.t.Fatal(err)
	}
	return page
}

// item pulls everything and returns the Item with id, failing if it is absent.
func (e *syncEnv) item(id string) pulledItem {
	e.t.Helper()
	for cursor := int64(0); ; {
		page := e.pull(cursor)
		for _, it := range page.Items {
			if it.ID == id {
				return it
			}
		}
		if !page.HasMore {
			e.t.Fatalf("item %s not in pull", id)
		}
		cursor = page.Cursor
	}
}

func textOf(it pulledItem) string {
	if it.Text == nil {
		return "<nil>"
	}
	return *it.Text
}

func TestCaptureOnPhoneReachesDesktop(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()

	results := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "buy oat milk"})
	if results[0].Status != "accepted" {
		t.Fatalf("capture result = %+v, want accepted", results[0])
	}

	page := e.pull(0)
	if len(page.Items) != 1 || page.Items[0].ID != itemID || textOf(page.Items[0]) != "buy oat milk" {
		t.Fatalf("desktop pulled %+v, want the one captured Item", page.Items)
	}
	if page.Items[0].TopicID != nil || page.Items[0].DeletedAt != nil {
		t.Fatalf("pulled Item = %+v, want in Inbox and not in Trash", page.Items[0])
	}
	if !page.Items[0].CaptureTime.Equal(syncBase) {
		t.Fatalf("capture_time = %v, want the Device's timestamp", page.Items[0].CaptureTime)
	}

	if later := e.pull(page.Cursor); len(later.Items) != 0 || later.HasMore {
		t.Fatalf("pull from returned cursor = %+v, want nothing new", later)
	}
}

// The Server's own time zone (PDT on a dev Mac) must never leak into the API.
func TestPulledTimesAreUTC(t *testing.T) {
	e := newSyncEnv(t)
	itemID, topicID := uuid.NewString(), uuid.NewString()
	e.push(phoneID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": topicID, "name": "Gym"},
		op{"type": "DeleteTopic", "at": e.at(1), "topic_id": topicID},
		op{"type": "CaptureItem", "at": "2026-10-04T05:00:00-07:00", "item_id": itemID, "text": "x"},
		op{"type": "TrashItem", "at": e.at(2), "item_id": itemID})

	var page struct {
		Items  []map[string]any
		Topics []map[string]any
	}
	if err := json.Unmarshal(e.do("GET", "/sync/pull?cursor=0", nil).Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	got := []any{page.Items[0]["capture_time"], page.Items[0]["deleted_at"], page.Items[0]["purge_at"], page.Topics[0]["deleted_at"], page.Topics[0]["activity_at"]}
	if got[0] != "2026-10-04T12:00:00Z" {
		t.Errorf("capture_time = %v, want 2026-10-04T12:00:00Z", got[0])
	}
	for _, v := range got {
		if s, _ := v.(string); !strings.HasSuffix(s, "Z") {
			t.Errorf("pulled time %v is not UTC", v)
		}
	}
}

func TestReplayingAPushChangesNothing(t *testing.T) {
	e := newSyncEnv(t)
	ops := []op{
		{"type": "CaptureItem", "at": e.at(0), "item_id": uuid.NewString(), "text": "first"},
		{"type": "CaptureItem", "at": e.at(1), "item_id": uuid.NewString(), "text": "second"},
	}
	first := e.push(phoneID, ops...)
	cursor := e.pull(0).Cursor

	// The phone never saw the response, so it sends the same batch again.
	replay := e.push(phoneID, ops...)
	for i := range ops {
		if replay[i] != first[i] {
			t.Errorf("replayed op %d = %+v, want first result %+v", i, replay[i], first[i])
		}
	}
	if page := e.pull(cursor); len(page.Items) != 0 {
		t.Fatalf("pull after replay = %+v, want no changes", page.Items)
	}
}

func newAttachment(name string) map[string]any {
	return map[string]any{"id": uuid.NewString(), "filename": name, "mime_type": "image/jpeg", "size_bytes": 2048}
}

func attachmentNames(it pulledItem) []string {
	names := []string{}
	for _, a := range it.Attachments {
		names = append(names, a.Filename)
	}
	return names
}

func TestImageOnlyCaptureIsLive(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	res := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID,
		"attachments": []any{newAttachment("receipt.jpg")}})

	it := e.item(itemID)
	if res[0].Status != "accepted" || it.DeletedAt != nil || it.Text != nil {
		t.Fatalf("image-only capture: result %+v, item %+v; want accepted, live, no text", res[0], it)
	}
	if got := it.Attachments; len(got) != 1 || got[0].Filename != "receipt.jpg" || got[0].MimeType != "image/jpeg" || got[0].SizeBytes != 2048 {
		t.Fatalf("attachments = %+v, want receipt.jpg", got)
	}
}

func TestEmptyCaptureIsRejected(t *testing.T) {
	e := newSyncEnv(t)
	res := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": uuid.NewString()})
	if res[0].Status != "rejected" || res[0].Reason != "invalid" {
		t.Fatalf("capture with no text or Attachments = %+v, want rejected invalid", res[0])
	}
}

func TestAttachmentsAddedOnTwoOfflineDevicesBothSurvive(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "trip"})
	cursor := e.pull(0).Cursor

	e.push(phoneID, op{"type": "AddAttachment", "at": e.at(5), "item_id": itemID, "attachment": newAttachment("P.jpg")})
	e.push(desktopID, op{"type": "AddAttachment", "at": e.at(6), "item_id": itemID, "attachment": newAttachment("S.jpg")})

	page := e.pull(cursor)
	if len(page.Items) != 1 {
		t.Fatalf("pull after adds = %+v, want the Item again", page.Items)
	}
	if got := attachmentNames(page.Items[0]); len(got) != 2 || got[0] != "P.jpg" || got[1] != "S.jpg" {
		t.Fatalf("attachments = %v, want [P.jpg S.jpg]", got)
	}
}

func TestRemovingAnAttachmentKeepsTheOthers(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	p, s := newAttachment("P.jpg"), newAttachment("S.jpg")
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "trip", "attachments": []any{p, s}})

	e.push(desktopID, op{"type": "RemoveAttachment", "at": e.at(5), "item_id": itemID, "attachment_id": p["id"]})

	if got := attachmentNames(e.item(itemID)); len(got) != 1 || got[0] != "S.jpg" {
		t.Fatalf("attachments = %v, want [S.jpg]", got)
	}
}

// topic pulls everything and returns the Topic with id, failing if it is absent.
func (e *syncEnv) topic(id string) pulledTopic {
	e.t.Helper()
	for cursor := int64(0); ; {
		page := e.pull(cursor)
		for _, tp := range page.Topics {
			if tp.ID == id {
				return tp
			}
		}
		if !page.HasMore {
			e.t.Fatalf("topic %s not in pull", id)
		}
		cursor = page.Cursor
	}
}

func TestTopicNameClashesGetANumberIgnoringCase(t *testing.T) {
	e := newSyncEnv(t)
	gym, gym1, gym2 := uuid.NewString(), uuid.NewString(), uuid.NewString()

	first := e.push(phoneID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"})
	second := e.push(desktopID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym1, "name": "gym"})
	third := e.push(desktopID, op{"type": "CreateTopic", "at": e.at(1), "topic_id": gym2, "name": "GYM"})

	if first[0].Status != "accepted" {
		t.Errorf("first Gym = %+v, want accepted", first[0])
	}
	for _, res := range []pushResult{second[0], third[0]} {
		if res.Status != "changed" || res.Reason != "renamed" {
			t.Errorf("clashing name = %+v, want changed renamed", res)
		}
	}
	for id, want := range map[string]string{gym: "Gym", gym1: "gym (1)", gym2: "GYM (2)"} {
		if got := e.topic(id).Name; got != want {
			t.Errorf("topic name = %q, want %q", got, want)
		}
	}
}

func TestRenameIntoATakenNameGetsANumber(t *testing.T) {
	e := newSyncEnv(t)
	gym, lifting := uuid.NewString(), uuid.NewString()
	e.push(phoneID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": lifting, "name": "Lifting"})

	res := e.push(desktopID, op{"type": "RenameTopic", "at": e.at(5), "topic_id": lifting, "name": "gym"})
	e.push(phoneID, op{"type": "RenameTopic", "at": e.at(6), "topic_id": gym, "name": "GYM"})

	if res[0].Status != "changed" || e.topic(lifting).Name != "gym (1)" {
		t.Errorf("rename into taken name: result %+v, name %q; want changed, gym (1)", res[0], e.topic(lifting).Name)
	}
	if got := e.topic(gym).Name; got != "GYM" {
		t.Errorf("renaming a Topic's own case = %q, want GYM", got)
	}
}

func TestLaterRenameWins(t *testing.T) {
	e := newSyncEnv(t)
	topicID := uuid.NewString()
	e.push(phoneID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": topicID, "name": "Gym"})

	e.push(desktopID, op{"type": "RenameTopic", "at": e.at(10), "topic_id": topicID, "name": "Lifting"})
	late := e.push(phoneID, op{"type": "RenameTopic", "at": e.at(5), "topic_id": topicID, "name": "Workouts"})

	if late[0].Reason != "superseded" || e.topic(topicID).Name != "Lifting" {
		t.Fatalf("older rename: result %+v, name %q; want superseded, Lifting", late[0], e.topic(topicID).Name)
	}
}

func TestBlankTopicNameIsRejected(t *testing.T) {
	e := newSyncEnv(t)
	res := e.push(phoneID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": uuid.NewString(), "name": "   "})
	if res[0].Status != "rejected" || res[0].Reason != "invalid" {
		t.Fatalf("blank name = %+v, want rejected invalid", res[0])
	}
}

func TestBuiltInBlankAndControlTopicNamesAreRejected(t *testing.T) {
	e := newSyncEnv(t)
	renamed := uuid.NewString()
	e.push(phoneID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": renamed, "name": "Gym"})
	for _, name := range []string{"inbox", " TUNNEL ", "Trash", "all items", "Anywhere", "New Topic", "new topic…", "New Topic...", "\u200b", " \u2060\ufeff ", "a\nb", "tab\there"} {
		create := e.push(phoneID, op{"type": "CreateTopic", "at": e.at(1), "topic_id": uuid.NewString(), "name": name})
		rename := e.push(phoneID, op{"type": "RenameTopic", "at": e.at(1), "topic_id": renamed, "name": name})
		if create[0].Reason != "invalid" || rename[0].Reason != "invalid" {
			t.Errorf("%q: create %+v, rename %+v; want both rejected invalid", name, create[0], rename[0])
		}
	}
	for _, name := range []string{"Inbox ideas", "New Topics", "Mom's recipes; DROP TABLE topics", "Ünïcode"} {
		if res := e.push(phoneID, op{"type": "CreateTopic", "at": e.at(2), "topic_id": uuid.NewString(), "name": name}); res[0].Status != "accepted" {
			t.Errorf("%q = %+v, want accepted", name, res[0])
		}
	}
}

func topicOf(it pulledItem) string {
	if it.TopicID == nil {
		return "Inbox"
	}
	return *it.TopicID
}

func TestCaptureIntoATopicDeletedMeanwhileLandsInInbox(t *testing.T) {
	e := newSyncEnv(t)
	gym, itemID := uuid.NewString(), uuid.NewString()
	e.push(desktopID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"})

	e.push(desktopID, op{"type": "DeleteTopic", "at": e.at(10), "topic_id": gym})
	res := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(5), "item_id": itemID, "topic_id": gym, "text": "squat 100"})

	if res[0].Status != "changed" || res[0].Reason != "sent_to_inbox" {
		t.Errorf("capture result = %+v, want changed sent_to_inbox", res[0])
	}
	if got := topicOf(e.item(itemID)); got != "Inbox" {
		t.Fatalf("Item is in %s, want Inbox", got)
	}
	if e.topic(gym).DeletedAt == nil {
		t.Fatalf("Gym not deleted")
	}
}

func TestCaptureIntoAnUnknownTopicLandsInInbox(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	res := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "topic_id": uuid.NewString(), "text": "x"})
	if res[0].Status != "changed" || topicOf(e.item(itemID)) != "Inbox" {
		t.Fatalf("capture into unknown Topic: result %+v; want changed, in Inbox", res[0])
	}
}

func TestMoveIntoADeletedTopicIsRejected(t *testing.T) {
	e := newSyncEnv(t)
	gym, itemID := uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "DeleteTopic", "at": e.at(1), "topic_id": gym},
		op{"type": "CaptureItem", "at": e.at(2), "item_id": itemID, "text": "squat 100"})

	res := e.push(phoneID, op{"type": "MoveItem", "at": e.at(3), "item_id": itemID, "topic_id": gym})
	if res[0].Status != "rejected" || res[0].Reason != "topic_unavailable" || topicOf(e.item(itemID)) != "Inbox" {
		t.Fatalf("move into deleted Topic: result %+v; want rejected topic_unavailable, Item stays in Inbox", res[0])
	}
}

func TestLaterMoveWins(t *testing.T) {
	e := newSyncEnv(t)
	gym, work, itemID := uuid.NewString(), uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": work, "name": "Work"},
		op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "text": "x"})

	e.push(desktopID, op{"type": "MoveItem", "at": e.at(10), "item_id": itemID, "topic_id": work})
	late := e.push(phoneID, op{"type": "MoveItem", "at": e.at(5), "item_id": itemID, "topic_id": gym})

	if late[0].Reason != "superseded" || topicOf(e.item(itemID)) != work {
		t.Fatalf("older move: result %+v, Item in %s; want superseded, in Work", late[0], topicOf(e.item(itemID)))
	}

	e.push(phoneID, op{"type": "MoveItem", "at": e.at(20), "item_id": itemID, "topic_id": nil})
	if got := topicOf(e.item(itemID)); got != "Inbox" {
		t.Fatalf("move to Inbox: Item in %s", got)
	}
}

func TestTrashAndAConcurrentEditAreOrderedByTimestamp(t *testing.T) {
	cases := []struct {
		name             string
		trashAt, editAt  int
		editArrivesFirst bool
		wantTrashed      bool
	}{
		{"delete 9:00, edit 9:30, delete arrives first", 0, 30, false, false},
		{"delete 9:00, edit 9:30, edit arrives first", 0, 30, true, false},
		{"edit 9:00, delete 9:30, delete arrives first", 30, 0, false, true},
		{"edit 9:00, delete 9:30, edit arrives first", 30, 0, true, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := newSyncEnv(t)
			itemID := uuid.NewString()
			e.push(phoneID, op{"type": "CaptureItem", "at": e.at(-60), "item_id": itemID, "text": "draft"})

			trash := func() { e.push(desktopID, op{"type": "TrashItem", "at": e.at(c.trashAt), "item_id": itemID}) }
			edit := func() {
				e.push(phoneID, op{"type": "SetText", "base_rev": 0, "at": e.at(c.editAt), "item_id": itemID, "text": "edited"})
			}
			if c.editArrivesFirst {
				edit()
				trash()
			} else {
				trash()
				edit()
			}

			it := e.item(itemID)
			if textOf(it) != "edited" || (it.DeletedAt != nil) != c.wantTrashed {
				t.Fatalf("Item = text %q, in Trash %v; want text edited, in Trash %v", textOf(it), it.DeletedAt != nil, c.wantTrashed)
			}
		})
	}
}

func TestMoveOrAddAttachmentAfterATrashRestores(t *testing.T) {
	e := newSyncEnv(t)
	moved, added := uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CaptureItem", "at": e.at(0), "item_id": moved, "text": "a"},
		op{"type": "CaptureItem", "at": e.at(0), "item_id": added, "text": "b"},
		op{"type": "TrashItem", "at": e.at(10), "item_id": moved},
		op{"type": "TrashItem", "at": e.at(10), "item_id": added})

	e.push(phoneID,
		op{"type": "MoveItem", "at": e.at(20), "item_id": moved, "topic_id": nil},
		op{"type": "AddAttachment", "at": e.at(20), "item_id": added, "attachment": newAttachment("P.jpg")})

	for _, id := range []string{moved, added} {
		if e.item(id).DeletedAt != nil {
			t.Errorf("Item edited after its Trash is still in Trash")
		}
	}
}

func TestRemovingAnAttachmentDoesNotRestore(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	p, s := newAttachment("P.jpg"), newAttachment("S.jpg")
	e.push(desktopID,
		op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "trip", "attachments": []any{p, s}},
		op{"type": "TrashItem", "at": e.at(10), "item_id": itemID})

	e.push(phoneID, op{"type": "RemoveAttachment", "at": e.at(20), "item_id": itemID, "attachment_id": p["id"]})

	it := e.item(itemID)
	if it.DeletedAt == nil || len(it.Attachments) != 1 {
		t.Fatalf("Item = %+v; want still in Trash with one Attachment", it)
	}
}

func TestTrashAndRestore(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "x"})

	// Trashed offline a day ago: the 30 days start when the Server hears of it, so none are lost.
	e.push(phoneID, op{"type": "TrashItem", "at": e.at(10), "item_id": itemID})
	if it := e.item(itemID); it.DeletedAt == nil || !it.DeletedAt.Equal(e.clock.Now()) {
		t.Fatalf("deleted_at = %v, want the Server's now %v", it.DeletedAt, e.clock.Now())
	}

	late := e.push(desktopID, op{"type": "RestoreItem", "at": e.at(5), "item_id": itemID})
	if late[0].Reason != "superseded" || e.item(itemID).DeletedAt == nil {
		t.Fatalf("restore older than the Trash = %+v; want superseded, still in Trash", late[0])
	}

	e.push(desktopID, op{"type": "RestoreItem", "at": e.at(20), "item_id": itemID})
	if it := e.item(itemID); it.DeletedAt != nil || it.PurgeAt != nil {
		t.Fatalf("after a later restore deleted_at = %v purge_at = %v, want both null", it.DeletedAt, it.PurgeAt)
	}
}

func TestItemEmptiedByTwoDevicesGoesToTrashAndCannotBeRestored(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	p := newAttachment("P.jpg")
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "caption", "attachments": []any{p}})

	// Each Device leaves something behind locally; together they leave nothing.
	e.push(desktopID, op{"type": "SetText", "base_rev": 0, "at": e.at(10), "item_id": itemID, "text": nil})
	e.push(phoneID, op{"type": "RemoveAttachment", "at": e.at(11), "item_id": itemID, "attachment_id": p["id"]})

	if it := e.item(itemID); it.DeletedAt == nil || !it.DeletedAt.Equal(e.clock.Now()) {
		t.Fatalf("empty Item deleted_at = %v, want in Trash from the Server's now", it.DeletedAt)
	}
	res := e.push(desktopID, op{"type": "RestoreItem", "at": e.at(20), "item_id": itemID})
	if res[0].Status != "rejected" || res[0].Reason != "empty" || e.item(itemID).DeletedAt == nil {
		t.Fatalf("restore of empty Item = %+v; want rejected empty, still in Trash", res[0])
	}
}

func TestDeleteTopicTrashesListedItemsAndSendsTheRestToInbox(t *testing.T) {
	e := newSyncEnv(t)
	gym, kept, trashed, concurrent, late := uuid.NewString(), uuid.NewString(), uuid.NewString(), uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "CaptureItem", "at": e.at(1), "item_id": kept, "topic_id": gym, "text": "keep me"},
		op{"type": "CaptureItem", "at": e.at(2), "item_id": trashed, "topic_id": gym, "text": "bin me"})

	// The phone captures into Gym before the desktop's delete arrives; the desktop never saw it.
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(5), "item_id": concurrent, "topic_id": gym, "text": "new set"})
	e.push(desktopID, op{"type": "DeleteTopic", "at": e.at(10), "topic_id": gym, "trash": []string{trashed}})
	// And one more that reaches the Server after the delete.
	res := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(6), "item_id": late, "topic_id": gym, "text": "late set"})

	for id, wantTrashed := range map[string]bool{kept: false, trashed: true, concurrent: false, late: false} {
		it := e.item(id)
		if topicOf(it) != "Inbox" || (it.DeletedAt != nil) != wantTrashed {
			t.Errorf("Item %q: in %s, in Trash %v; want Inbox, in Trash %v", textOf(it), topicOf(it), it.DeletedAt != nil, wantTrashed)
		}
	}
	if res[0].Reason != "sent_to_inbox" {
		t.Errorf("capture after delete = %+v, want sent_to_inbox", res[0])
	}
	if e.topic(gym).DeletedAt == nil {
		t.Errorf("Gym not deleted")
	}
}

func TestDeletingATopicIsFinal(t *testing.T) {
	e := newSyncEnv(t)
	gym := uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "DeleteTopic", "at": e.at(10), "topic_id": gym, "trash": []string{}})

	for _, o := range []op{
		{"type": "RenameTopic", "at": e.at(20), "topic_id": gym, "name": "Lifting"},
		{"type": "DeleteTopic", "at": e.at(20), "topic_id": gym, "trash": []string{}},
	} {
		if res := e.push(phoneID, o); res[0].Reason != "topic_deleted" {
			t.Errorf("%s after delete = %+v, want rejected topic_deleted", o["type"], res[0])
		}
	}
	if tp := e.topic(gym); tp.Name != "Gym" || tp.DeletedAt == nil {
		t.Errorf("deleted Topic changed: %+v", tp)
	}

	again := uuid.NewString()
	if res := e.push(phoneID, op{"type": "CreateTopic", "at": e.at(30), "topic_id": again, "name": "Gym"}); res[0].Status != "accepted" {
		t.Errorf("reusing a deleted Topic's name = %+v, want accepted", res[0])
	}
}

func TestRestoringAnItemWhoseTopicWasDeletedPutsItInInbox(t *testing.T) {
	e := newSyncEnv(t)
	gym, itemID := uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "topic_id": gym, "text": "x"},
		op{"type": "TrashItem", "at": e.at(2), "item_id": itemID},
		op{"type": "DeleteTopic", "at": e.at(3), "topic_id": gym, "trash": []string{}})

	e.push(desktopID, op{"type": "RestoreItem", "at": e.at(4), "item_id": itemID})

	if it := e.item(itemID); it.DeletedAt != nil || topicOf(it) != "Inbox" {
		t.Fatalf("restored Item: in %s, in Trash %v; want Inbox, live", topicOf(it), it.DeletedAt != nil)
	}
}

func TestPullPagesThroughEveryChangeOnce(t *testing.T) {
	e := newSyncEnv(t)
	want := map[string]bool{}
	var ops []op
	for i := range 600 {
		id := uuid.NewString()
		want[id] = true
		ops = append(ops, op{"type": "CaptureItem", "at": e.at(i), "item_id": id, "text": "x"})
	}
	e.push(phoneID, ops[:500]...)
	topicID := uuid.NewString()
	want[topicID] = true
	e.push(desktopID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": topicID, "name": "Gym"})
	e.push(phoneID, ops[500:]...)

	seen := map[string]int{}
	pages := 0
	for cursor := int64(0); ; {
		page := e.pull(cursor)
		pages++
		if n := len(page.Items) + len(page.Topics); n > 500 {
			t.Fatalf("page %d has %d changes, want at most 500", pages, n)
		}
		for _, it := range page.Items {
			seen[it.ID]++
		}
		for _, tp := range page.Topics {
			seen[tp.ID]++
		}
		if !page.HasMore {
			break
		}
		cursor = page.Cursor
	}
	if pages != 2 || len(seen) != len(want) {
		t.Fatalf("pulled %d distinct changes in %d pages, want %d in 2", len(seen), pages, len(want))
	}
	for id, n := range seen {
		if !want[id] || n != 1 {
			t.Fatalf("change %s pulled %d times", id, n)
		}
	}
}

func TestTrashAfterCopyStartsUnasked(t *testing.T) {
	e := newSyncEnv(t)
	rec := e.do("GET", "/sync/pull?cursor=0", nil)
	if !strings.Contains(rec.Body.String(), `"settings":{"trash_after_copy":null}`) {
		t.Fatalf("pull = %s; want settings.trash_after_copy null", rec.Body)
	}
}

func TestLaterTrashAfterCopyWins(t *testing.T) {
	for _, order := range []string{"newer first", "older first"} {
		t.Run(order, func(t *testing.T) {
			e := newSyncEnv(t)
			newer := op{"type": "SetTrashAfterCopy", "at": e.at(2), "value": true}
			older := op{"type": "SetTrashAfterCopy", "at": e.at(1), "value": false}
			first, second := []any{desktopID, newer}, []any{phoneID, older}
			if order == "older first" {
				first, second = second, first
			}
			e.push(first[0].(string), first[1].(op))
			res := e.push(second[0].(string), second[1].(op))
			if got := e.pull(0).Settings.TrashAfterCopy; got == nil || !*got {
				t.Fatalf("trash_after_copy = %v; want true", got)
			}
			if order == "newer first" && (res[0].Status != "rejected" || res[0].Reason != "superseded") {
				t.Fatalf("older op: %+v; want rejected superseded", res[0])
			}
			if order == "older first" && res[0].Status != "accepted" {
				t.Fatalf("newer op: %+v; want accepted", res[0])
			}
		})
	}
}

func TestTrashAfterCopyNeedsAValue(t *testing.T) {
	e := newSyncEnv(t)
	res := e.push(phoneID, op{"type": "SetTrashAfterCopy", "at": e.at(1)})
	if res[0].Status != "rejected" || res[0].Reason != "invalid" {
		t.Fatalf("no value: %+v; want rejected invalid", res[0])
	}
	if got := e.pull(0).Settings.TrashAfterCopy; got != nil {
		t.Fatalf("trash_after_copy = %v; want still null", *got)
	}
}

func TestEveryPullPageCarriesSettings(t *testing.T) {
	e := newSyncEnv(t)
	var ops []op
	for i := range 501 {
		ops = append(ops, op{"type": "CaptureItem", "at": e.at(i), "item_id": uuid.NewString(), "text": "x"})
	}
	e.push(phoneID, ops[:500]...)
	e.push(phoneID, ops[500:]...)
	e.push(phoneID, op{"type": "SetTrashAfterCopy", "at": e.at(1), "value": true})
	first := e.pull(0)
	if !first.HasMore {
		t.Fatal("want a multi-page pull")
	}
	for _, page := range []pullPage{first, e.pull(first.Cursor)} {
		if got := page.Settings.TrashAfterCopy; got == nil || !*got {
			t.Fatalf("page settings = %v; want true on every page", got)
		}
	}
}

func TestPushLimits(t *testing.T) {
	e := newSyncEnv(t)

	tooLong := strings.Repeat("a", 1<<20+1)
	res := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": uuid.NewString(), "text": tooLong})
	if res[0].Reason != "invalid" {
		t.Errorf("text over 1 MB = %+v, want rejected invalid", res[0])
	}

	var ops []map[string]any
	for range 501 {
		ops = append(ops, op{"id": uuid.NewString(), "type": "CaptureItem", "at": e.at(0), "item_id": uuid.NewString(), "text": "x"})
	}
	body, _ := json.Marshal(map[string]any{"device_id": phoneID, "ops": ops})
	if rec := e.do("POST", "/sync/push", body); rec.Code != http.StatusBadRequest {
		t.Errorf("501 ops = %d, want 400", rec.Code)
	}

	body, _ = json.Marshal(map[string]any{"device_id": phoneID, "ops": []any{}, "padding": strings.Repeat("a", 16<<20)})
	if rec := e.do("POST", "/sync/push", body); rec.Code != http.StatusRequestEntityTooLarge {
		t.Errorf("body over 16 MB = %d, want 413", rec.Code)
	}

	body, _ = json.Marshal(map[string]any{"ops": []any{}})
	if rec := e.do("POST", "/sync/push", body); rec.Code != http.StatusBadRequest {
		t.Errorf("push without device_id = %d, want 400", rec.Code)
	}

	if rec := e.do("GET", "/sync/pull?cursor=-1", nil); rec.Code != http.StatusBadRequest {
		t.Errorf("negative cursor = %d, want 400", rec.Code)
	}
}

func TestInvalidOpsAreRejectedOneByOne(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	att := newAttachment("P.jpg")
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "x", "attachments": []any{att}})

	big := newAttachment("huge.mov")
	big["size_bytes"] = 100<<20 + 1
	longName := newAttachment(strings.Repeat("a", 256))
	dup := newAttachment("dup.jpg")
	cases := map[string]struct {
		o    op
		want string
	}{
		"attachment over 100 MB":       {op{"type": "AddAttachment", "at": e.at(1), "item_id": itemID, "attachment": big}, "invalid"},
		"filename over 255 bytes":      {op{"type": "AddAttachment", "at": e.at(1), "item_id": itemID, "attachment": longName}, "invalid"},
		"topic name over 200 bytes":    {op{"type": "CreateTopic", "at": e.at(1), "topic_id": uuid.NewString(), "name": strings.Repeat("a", 201)}, "invalid"},
		"attachment id reused":         {op{"type": "AddAttachment", "at": e.at(1), "item_id": itemID, "attachment": att}, "exists"},
		"same attachment twice":        {op{"type": "CaptureItem", "at": e.at(1), "item_id": uuid.NewString(), "attachments": []any{dup, dup}}, "invalid"},
		"remove unknown attachment":    {op{"type": "RemoveAttachment", "at": e.at(1), "item_id": itemID, "attachment_id": uuid.NewString()}, "not_found"},
		"edit unknown item":            {op{"type": "SetText", "base_rev": 0, "at": e.at(1), "item_id": uuid.NewString(), "text": "x"}, "not_found"},
		"unknown op type":              {op{"type": "Explode", "at": e.at(1)}, "invalid"},
		"timestamp that doesn't parse": {op{"type": "SetText", "base_rev": 0, "at": "yesterday", "item_id": itemID, "text": "x"}, "invalid"},
		"missing op id":                {op{"id": "", "type": "SetText", "base_rev": 0, "at": e.at(1), "item_id": itemID, "text": "x"}, "invalid"},
	}
	for name, c := range cases {
		// A good op after the bad one must still apply: one bad op never blocks the queue.
		res := e.push(phoneID, c.o, op{"type": "SetText", "base_rev": 0, "at": e.at(2), "item_id": itemID, "text": name})
		if res[0].Status != "rejected" || res[0].Reason != c.want || res[1].Status != "accepted" {
			t.Errorf("%s: results %+v, want rejected %s then accepted", name, res, c.want)
		}
	}
}

// Postgres text can't hold NUL; letting one through would fail the whole batch on every retry.
func TestNulCharactersAreRejectedNotFatal(t *testing.T) {
	e := newSyncEnv(t)
	bad := "a\x00b"
	att := newAttachment("ok.jpg")
	att["filename"] = bad
	res := e.push(phoneID,
		op{"type": "CaptureItem", "at": e.at(0), "item_id": uuid.NewString(), "text": bad},
		op{"type": "CaptureItem", "at": e.at(0), "item_id": uuid.NewString(), "attachments": []any{att}},
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": uuid.NewString(), "name": bad})
	for i, r := range res {
		if r.Reason != "invalid" {
			t.Errorf("op %d with NUL = %+v, want rejected invalid", i, r)
		}
	}
}

func TestSyncNeedsTheSecret(t *testing.T) {
	e := newSyncEnv(t)
	for _, path := range []string{"POST /sync/push", "GET /sync/pull?cursor=0"} {
		method, target, _ := strings.Cut(path, " ")
		if got := request(e.h, method, target, "203.0.113.1:5000", ""); got != http.StatusUnauthorized {
			t.Errorf("%s without secret = %d, want 401", path, got)
		}
	}
}

func TestLaterTextEditWinsWhicheverArrivesFirst(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "draft"})

	e.push(desktopID, op{"type": "SetText", "base_rev": 0, "at": e.at(10), "item_id": itemID, "text": "desktop at 10"})
	late := e.push(phoneID, op{"type": "SetText", "base_rev": 0, "at": e.at(5), "item_id": itemID, "text": "phone at 5"})

	if late[0].Status != "rejected" || late[0].Reason != "superseded" {
		t.Errorf("older edit arriving later = %+v, want rejected superseded", late[0])
	}
	if got := textOf(e.item(itemID)); got != "desktop at 10" {
		t.Fatalf("text = %q, want the later edit", got)
	}
}

func TestSimultaneousEditsGoToTheLowerDeviceID(t *testing.T) {
	e := newSyncEnv(t)
	first, second := uuid.NewString(), uuid.NewString()
	e.push(phoneID,
		op{"type": "CaptureItem", "at": e.at(0), "item_id": first, "text": "draft"},
		op{"type": "CaptureItem", "at": e.at(0), "item_id": second, "text": "draft"})

	e.push(desktopID, op{"type": "SetText", "base_rev": 0, "at": e.at(10), "item_id": first, "text": "desktop"})
	e.push(phoneID, op{"type": "SetText", "base_rev": 0, "at": e.at(10), "item_id": first, "text": "phone"})
	e.push(phoneID, op{"type": "SetText", "base_rev": 0, "at": e.at(10), "item_id": second, "text": "phone"})
	e.push(desktopID, op{"type": "SetText", "base_rev": 0, "at": e.at(10), "item_id": second, "text": "desktop"})

	for _, id := range []string{first, second} {
		if got := textOf(e.item(id)); got != "phone" {
			t.Errorf("text after a tie = %q, want the phone's (lower Device id)", got)
		}
	}
}

func TestADevicesOwnEditsApplyInOrderAtTheSameTimestamp(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.push(phoneID,
		op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "a"},
		op{"type": "SetText", "base_rev": 0, "at": e.at(0), "item_id": itemID, "text": "ab"})
	if got := textOf(e.item(itemID)); got != "ab" {
		t.Fatalf("text = %q, want the later op from the same Device", got)
	}
}

func TestFutureTimestampsAreCappedAtServerTime(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "draft"})

	// The Server's now is at(day). The phone's clock is a day fast, so its edit counts as made at now.
	day := 24 * 60
	e.push(phoneID, op{"type": "SetText", "base_rev": 0, "at": e.at(2 * day), "item_id": itemID, "text": "phone, clock a day fast"})
	e.clock.Advance(5 * time.Minute)
	e.push(desktopID, op{"type": "SetText", "base_rev": 0, "at": e.at(day + 2), "item_id": itemID, "text": "desktop, 2 minutes later"})

	if got := textOf(e.item(itemID)); got != "desktop, 2 minutes later" {
		t.Fatalf("text = %q, want the desktop's genuinely later edit", got)
	}
}

// A Device pulling while others push must never move its cursor past a change that commits later.
func TestConcurrentPushesNeverSkipAPullingDevice(t *testing.T) {
	e := newSyncEnv(t)
	const devices, pushesEach, opsPerPush = 20, 5, 5

	want := map[string]bool{}
	batches := make([][]op, devices*pushesEach)
	for i := range batches {
		for range opsPerPush {
			id := uuid.NewString()
			want[id] = true
			batches[i] = append(batches[i], op{"id": uuid.NewString(), "type": "CaptureItem", "at": e.at(0), "item_id": id, "text": "x"})
		}
		// Items and Topics are read by separate queries; a change to each in one push catches a pull mixing two snapshots.
		topicID := uuid.NewString()
		want[topicID] = true
		batches[i] = append(batches[i], op{"id": uuid.NewString(), "type": "CreateTopic", "at": e.at(0), "topic_id": topicID, "name": topicID})
	}

	seen := map[string]int{}
	var cursor int64
	pullOnce := func() bool {
		rec := e.do("GET", fmt.Sprintf("/sync/pull?cursor=%d", cursor), nil)
		var page pullPage
		if rec.Code != http.StatusOK || json.Unmarshal(rec.Body.Bytes(), &page) != nil {
			t.Errorf("pull = %d %s", rec.Code, rec.Body)
			return false
		}
		for _, it := range page.Items {
			seen[it.ID]++
		}
		for _, tp := range page.Topics {
			seen[tp.ID]++
		}
		cursor = page.Cursor
		return page.HasMore
	}

	var pushers sync.WaitGroup
	for d := range devices {
		pushers.Go(func() {
			device := fmt.Sprintf("00000000-0000-4000-8000-%012d", d+10)
			for p := range pushesEach {
				body, _ := json.Marshal(map[string]any{"device_id": device, "ops": batches[d*pushesEach+p]})
				if rec := e.do("POST", "/sync/push", body); rec.Code != http.StatusOK {
					t.Errorf("push = %d %s", rec.Code, rec.Body)
				}
			}
		})
	}
	done := make(chan struct{})
	go func() { pushers.Wait(); close(done) }()
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

	missed := 0
	for id := range want {
		if seen[id] != 1 {
			missed++
		}
	}
	if missed > 0 || len(seen) != len(want) {
		t.Fatalf("puller saw %d of %d changes, %d not exactly once", len(seen), len(want), missed)
	}
}

// cursor pulls everything and returns the cursor after the last change.
func (e *syncEnv) cursor() int64 {
	e.t.Helper()
	cursor := int64(0)
	for {
		page := e.pull(cursor)
		cursor = page.Cursor
		if !page.HasMore {
			return cursor
		}
	}
}

func changedIDs(page pullPage) []string {
	ids := []string{}
	for _, it := range page.Items {
		ids = append(ids, it.ID)
	}
	for _, tp := range page.Topics {
		ids = append(ids, tp.ID)
	}
	slices.Sort(ids)
	return ids
}

func TestARejectedOpMakesThePushingDevicePullTheRowsItNames(t *testing.T) {
	e := newSyncEnv(t)
	gym, gone, itemID, filed := uuid.NewString(), uuid.NewString(), uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gone, "name": "Gone"},
		op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "text": "x"},
		op{"type": "CaptureItem", "at": e.at(1), "item_id": filed, "topic_id": gone, "text": "y"},
		op{"type": "DeleteTopic", "at": e.at(3), "topic_id": gone, "trash": []string{}},
		op{"type": "RenameTopic", "at": e.at(10), "topic_id": gym, "name": "Lifting"})

	for _, tc := range []struct {
		name string
		o    op
		want []string
	}{
		{"move into a deleted Topic", op{"type": "MoveItem", "at": e.at(4), "item_id": itemID, "topic_id": gone}, []string{itemID, gone}},
		{"superseded rename", op{"type": "RenameTopic", "at": e.at(5), "topic_id": gym, "name": "Gym day"}, []string{gym}},
		{"delete of a deleted Topic", op{"type": "DeleteTopic", "at": e.at(6), "topic_id": gone, "trash": []string{filed}}, []string{filed, gone}},
	} {
		cursor := e.cursor()
		if res := e.push(phoneID, tc.o); res[0].Status != "rejected" {
			t.Fatalf("%s: result %+v, want rejected", tc.name, res[0])
		}
		want := slices.Sorted(slices.Values(tc.want))
		if got := changedIDs(e.pull(cursor)); !slices.Equal(got, want) {
			t.Errorf("%s: pulled %v, want %v", tc.name, got, want)
		}

		// push gave tc.o an id, so this is a replay.
		cursor = e.cursor()
		e.push(phoneID, tc.o)
		if got := changedIDs(e.pull(cursor)); len(got) != 0 {
			t.Errorf("%s: a replay re-marked %v", tc.name, got)
		}
	}
}

func TestAnAcceptedMoveSendsItemAndActiveTopic(t *testing.T) {
	e := newSyncEnv(t)
	gym, itemID := uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "text": "x"})
	cursor := e.cursor()

	if res := e.push(phoneID, op{"type": "MoveItem", "at": e.at(5), "item_id": itemID, "topic_id": gym}); res[0].Status != "accepted" {
		t.Fatalf("move = %+v, want accepted", res[0])
	}
	want := slices.Sorted(slices.Values([]string{itemID, gym}))
	if got := changedIDs(e.pull(cursor)); !slices.Equal(got, want) {
		t.Fatalf("pulled %v, want Item and active Topic %v", got, want)
	}
}

func setText(opID, itemID, text string, base any, at string) op {
	return op{"id": opID, "type": "SetText", "at": at, "item_id": itemID, "text": text, "base_rev": base}
}

func (e *syncEnv) capture(itemID string) {
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "draft"})
}

func TestAnEditFromTheCurrentRevisionApplies(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.capture(itemID)
	if rev := e.item(itemID).TextRev; rev != 0 {
		t.Fatalf("captured text_rev = %d, want 0", rev)
	}
	res := e.push(desktopID, setText(uuid.NewString(), itemID, "edited", 0, e.at(10)))
	if res[0].Status != "accepted" {
		t.Fatalf("result = %+v, want accepted", res[0])
	}
	if rev := e.item(itemID).TextRev; rev != 1 {
		t.Fatalf("text_rev = %d, want 1", rev)
	}
}

func TestAnOlderOverlappingEditIsSuperseded(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.capture(itemID)
	e.push(phoneID, setText(uuid.NewString(), itemID, "phone", 0, e.at(10)))
	res := e.push(desktopID, setText(uuid.NewString(), itemID, "desk", 0, e.at(5)))
	if res[0].Status != "rejected" || res[0].Reason != "superseded" || res[0].Text != nil {
		t.Fatalf("result = %+v, want rejected superseded without text", res[0])
	}
	if it := e.item(itemID); textOf(it) != "phone" || it.TextRev != 1 {
		t.Fatalf("item = %q rev %d, want the phone's text at rev 1", textOf(it), it.TextRev)
	}
}

func TestANewerOverlappingEditReturnsTheTextItReplaced(t *testing.T) {
	t.Run("text", func(t *testing.T) {
		e := newSyncEnv(t)
		itemID := uuid.NewString()
		e.capture(itemID)
		e.push(phoneID, setText(uuid.NewString(), itemID, "phone", 0, e.at(5)))
		res := e.push(desktopID, setText(uuid.NewString(), itemID, "desk", 0, e.at(10)))
		if res[0].Status != "changed" || res[0].Reason != "overwrote" || res[0].Text == nil || *res[0].Text != "phone" {
			t.Fatalf("result = %+v, want changed overwrote with the phone's text", res[0])
		}
		if it := e.item(itemID); textOf(it) != "desk" || it.TextRev != 2 {
			t.Fatalf("item = %q rev %d, want desk at rev 2", textOf(it), it.TextRev)
		}
	})
	t.Run("no text", func(t *testing.T) {
		e := newSyncEnv(t)
		itemID := uuid.NewString()
		e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "caption",
			"attachments": []any{newAttachment("a.jpg")}})
		e.push(phoneID, op{"type": "SetText", "at": e.at(5), "item_id": itemID, "text": nil, "base_rev": 0})
		res := e.push(desktopID, setText(uuid.NewString(), itemID, "desk", 0, e.at(10)))
		if res[0].Reason != "overwrote" || res[0].Text != nil {
			t.Fatalf("result = %+v, want overwrote with null text", res[0])
		}
		if got := textOf(e.item(itemID)); got != "desk" {
			t.Fatalf("text = %q, want desk", got)
		}
	})
}

func TestASlowClockEditFromTheCurrentRevisionApplies(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.capture(itemID)
	e.push(phoneID, setText(uuid.NewString(), itemID, "phone", 0, e.at(10)))
	res := e.push(desktopID, setText(uuid.NewString(), itemID, "desk", 1, e.at(5)))
	if res[0].Status != "accepted" {
		t.Fatalf("result = %+v, want accepted", res[0])
	}
	if got := textOf(e.item(itemID)); got != "desk" {
		t.Fatalf("text = %q, want the desktop's", got)
	}
}

func TestTwoQueuedEditsFromOneDeviceDontOverlapEachOther(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.capture(itemID)
	res := e.push(desktopID,
		setText(uuid.NewString(), itemID, "d1", 0, e.at(10)),
		setText(uuid.NewString(), itemID, "d2", 0, e.at(11)))
	if res[0].Status != "accepted" || res[1].Status != "accepted" {
		t.Fatalf("results = %+v, want both accepted", res)
	}
	if got := textOf(e.item(itemID)); got != "d2" {
		t.Fatalf("text = %q, want the last edit", got)
	}
}

func TestAnOverlapIsReportedOnceForAQueuedPair(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.capture(itemID)
	e.push(phoneID, setText(uuid.NewString(), itemID, "phone", 0, e.at(5)))
	res := e.push(desktopID,
		setText(uuid.NewString(), itemID, "d1", 0, e.at(10)),
		setText(uuid.NewString(), itemID, "d2", 0, e.at(11)))
	if res[0].Reason != "overwrote" || res[0].Text == nil || *res[0].Text != "phone" || res[1].Status != "accepted" {
		t.Fatalf("results = %+v, want overwrote (phone) then accepted", res)
	}
	if got := textOf(e.item(itemID)); got != "d2" {
		t.Fatalf("text = %q, want d2", got)
	}
}

func TestAReplayedOverwriteReturnsTheSameText(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.capture(itemID)
	e.push(phoneID, setText(uuid.NewString(), itemID, "phone", 0, e.at(5)))
	ops := []op{
		setText(uuid.NewString(), itemID, "d1", 0, e.at(10)),
		setText(uuid.NewString(), itemID, "d2", 0, e.at(11)),
	}
	first := e.push(desktopID, ops...)
	again := e.push(desktopID, ops...)
	if first[0].Text == nil || again[0].Text == nil || *again[0].Text != *first[0].Text ||
		again[0].Reason != first[0].Reason || again[1].Status != first[1].Status {
		t.Fatalf("replay = %+v, want %+v", again, first)
	}
}

func TestSetTextWithoutABaseRevIsInvalid(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.capture(itemID)
	res := e.push(desktopID, setText(uuid.NewString(), itemID, "x", nil, e.at(10)))
	if res[0].Status != "rejected" || res[0].Reason != "invalid" {
		t.Fatalf("result = %+v, want rejected invalid", res[0])
	}
}

func placeOf(it pulledItem) string {
	if it.Tunnel {
		return "Tunnel"
	}
	return topicOf(it)
}

func TestCaptureIntoTheTunnel(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	res := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "wifi pw", "tunnel": true})
	it := e.item(itemID)
	if res[0].Status != "accepted" || !it.Tunnel || it.TopicID != nil {
		t.Fatalf("capture into Tunnel: result %+v, tunnel %v, topic %v; want accepted, in Tunnel, no Topic", res[0], it.Tunnel, it.TopicID)
	}
}

func TestTunnelWithATopicIsInvalid(t *testing.T) {
	e := newSyncEnv(t)
	gym, itemID, other := uuid.NewString(), uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "text": "x"})

	res := e.push(phoneID,
		op{"type": "CaptureItem", "at": e.at(2), "item_id": other, "topic_id": gym, "text": "y", "tunnel": true},
		op{"type": "MoveItem", "at": e.at(3), "item_id": itemID, "topic_id": gym, "tunnel": true})

	for i, r := range res {
		if r.Status != "rejected" || r.Reason != "invalid" {
			t.Errorf("op %d = %+v, want rejected invalid", i, r)
		}
	}
	if got := placeOf(e.item(itemID)); got != "Inbox" {
		t.Errorf("moved Item is in %s, want Inbox", got)
	}
	for _, it := range e.pull(0).Items {
		if it.ID == other {
			t.Errorf("rejected Capture was written")
		}
	}
}

func TestMovingThroughTheTunnel(t *testing.T) {
	e := newSyncEnv(t)
	gym, itemID := uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "text": "x"})

	for i, step := range []struct {
		move op
		want string
	}{
		{op{"topic_id": nil, "tunnel": true}, "Tunnel"},
		{op{"topic_id": gym}, gym},
		{op{"topic_id": nil, "tunnel": true}, "Tunnel"},
		{op{"topic_id": nil}, "Inbox"},
	} {
		step.move["type"], step.move["item_id"], step.move["at"] = "MoveItem", itemID, e.at(10+i)
		res := e.push(phoneID, step.move)
		if res[0].Status != "accepted" || placeOf(e.item(itemID)) != step.want {
			t.Fatalf("step %d: result %+v, Item in %s; want accepted, in %s", i, res[0], placeOf(e.item(itemID)), step.want)
		}
	}
}

func TestLaterPlaceWinsBetweenTunnelAndTopic(t *testing.T) {
	e := newSyncEnv(t)
	gym := uuid.NewString()
	e.push(desktopID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"})

	toTunnel := func(itemID string) op {
		return op{"type": "MoveItem", "at": e.at(10), "item_id": itemID, "topic_id": nil, "tunnel": true}
	}
	toGym := func(itemID string) op {
		return op{"type": "MoveItem", "at": e.at(20), "item_id": itemID, "topic_id": gym}
	}
	for name, order := range map[string]func(string){
		"later arrives last":  func(id string) { e.push(phoneID, toTunnel(id)); e.push(desktopID, toGym(id)) },
		"later arrives first": func(id string) { e.push(desktopID, toGym(id)); e.push(phoneID, toTunnel(id)) },
	} {
		itemID := uuid.NewString()
		e.push(desktopID, op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "text": name})
		order(itemID)
		if got := placeOf(e.item(itemID)); got != gym {
			t.Errorf("%s: Item in %s, want Gym", name, got)
		}
	}

	itemID := uuid.NewString()
	e.push(desktopID, op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "text": "tunnel later"})
	e.push(phoneID, op{"type": "MoveItem", "at": e.at(10), "item_id": itemID, "topic_id": gym})
	res := e.push(desktopID, op{"type": "MoveItem", "at": e.at(20), "item_id": itemID, "topic_id": nil, "tunnel": true})
	if res[0].Status != "accepted" || placeOf(e.item(itemID)) != "Tunnel" {
		t.Errorf("later Tunnel move: result %+v, Item in %s; want accepted, in Tunnel", res[0], placeOf(e.item(itemID)))
	}
}

func TestTunnelItemRestoresToTheTunnel(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	e.push(phoneID,
		op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "x", "tunnel": true},
		op{"type": "TrashItem", "at": e.at(1), "item_id": itemID})
	if it := e.item(itemID); it.DeletedAt == nil || !it.Tunnel {
		t.Fatalf("trashed Item: in Trash %v, tunnel %v; want both", it.DeletedAt != nil, it.Tunnel)
	}

	e.push(phoneID, op{"type": "RestoreItem", "at": e.at(2), "item_id": itemID})
	if it := e.item(itemID); it.DeletedAt != nil || !it.Tunnel {
		t.Fatalf("restored Item: in Trash %v, tunnel %v; want live, in Tunnel", it.DeletedAt != nil, it.Tunnel)
	}
}

func TestDeleteTopicNeverTouchesTunnelItems(t *testing.T) {
	e := newSyncEnv(t)
	gym, itemID := uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "text": "x", "tunnel": true})

	e.push(desktopID, op{"type": "DeleteTopic", "at": e.at(10), "topic_id": gym, "trash": []string{itemID}})

	if it := e.item(itemID); !it.Tunnel || it.DeletedAt != nil {
		t.Fatalf("Tunnel Item after DeleteTopic: tunnel %v, in Trash %v; want in Tunnel, live", it.Tunnel, it.DeletedAt != nil)
	}
}

func TestTunnelCheckConstraint(t *testing.T) {
	e := newSyncEnv(t)
	gym, itemID := uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "text": "x"})

	_, err := e.h.api.db.Exec(context.Background(),
		`UPDATE items SET in_tunnel = true, topic_id = $2 WHERE id = $1`, itemID, gym)
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) || pgErr.Code != "23514" {
		t.Fatalf("UPDATE putting an Item in the Tunnel and a Topic = %v, want a CHECK violation", err)
	}
}

func TestArchiveOpsAreRejected(t *testing.T) {
	e := newSyncEnv(t)
	topicID, itemID := uuid.NewString(), uuid.NewString()
	e.push(desktopID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": topicID, "name": "Gym"})
	res := e.push(phoneID,
		op{"type": "ArchiveTopic", "at": e.at(1), "topic_id": topicID},
		op{"type": "UnarchiveTopic", "at": e.at(2), "topic_id": topicID},
		op{"type": "CaptureItem", "at": e.at(3), "item_id": itemID, "topic_id": topicID, "text": "squat 100"})
	for i := 0; i < 2; i++ {
		if res[i].Status != "rejected" || res[i].Reason != "invalid" {
			t.Errorf("archive op %d = %+v, want rejected invalid", i, res[i])
		}
	}
	if res[2].Status != "accepted" || topicOf(e.item(itemID)) != topicID || textOf(e.item(itemID)) != "squat 100" {
		t.Fatalf("mixed-batch capture = %+v, want accepted and saved in Gym", res[2])
	}
}

func TestPullTopicsHaveNoArchivedAt(t *testing.T) {
	e := newSyncEnv(t)
	topicID := uuid.NewString()
	e.push(phoneID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": topicID, "name": "Gym"})
	rec := e.do("GET", "/sync/pull?cursor=0", nil)
	if rec.Code != http.StatusOK {
		t.Fatalf("pull = %d %s", rec.Code, rec.Body)
	}
	var page struct{ Topics []map[string]any }
	if err := json.Unmarshal(rec.Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	if len(page.Topics) != 1 || page.Topics[0]["id"] != topicID || page.Topics[0]["name"] != "Gym" {
		t.Fatalf("pulled Topics = %+v, want Gym", page.Topics)
	}
	if _, exists := page.Topics[0]["archived_at"]; exists {
		t.Error("pulled Topic contains archived_at")
	}
	if deleted, exists := page.Topics[0]["deleted_at"]; !exists || deleted != nil {
		t.Errorf("deleted_at = %v (exists %v), want null", deleted, exists)
	}
}

func TestTopicActivityCreate(t *testing.T) {
	e := newSyncEnv(t)
	id := uuid.NewString()
	e.push(phoneID, op{"type": "CreateTopic", "at": "2026-10-04T05:00:00.123456-07:00", "topic_id": id, "name": "Work"})
	want := syncBase.Add(123456 * time.Microsecond)
	if got := e.topic(id).ActivityAt; !got.Equal(want) {
		t.Errorf("activity_at = %v, want %v", got, want)
	}
}

func TestTopicActivityOperations(t *testing.T) {
	for _, tc := range []struct {
		name, kind     string
		at, want       int
		status, reason string
	}{
		{"capture raises", "CaptureItem", 20, 20, "accepted", ""},
		{"older capture", "CaptureItem", 5, 10, "accepted", ""},
		{"equal capture", "CaptureItem", 10, 10, "accepted", ""},
		{"move in", "MoveItem", 20, 20, "accepted", ""},
		{"older accepted move", "MoveItem", 5, 10, "accepted", ""},
		{"superseded move", "MoveItem", 0, 10, "rejected", "superseded"},
		{"move out", "MoveOut", 20, 10, "accepted", ""},
		{"edit", "SetText", 20, 10, "accepted", ""},
		{"trash", "TrashItem", 20, 10, "accepted", ""},
		{"restore", "RestoreItem", 20, 10, "accepted", ""},
		{"rename", "RenameTopic", 20, 10, "accepted", ""},
		{"redirected capture", "RedirectCapture", 20, 10, "changed", "sent_to_inbox"},
		{"rejected move", "RejectedMove", 20, 10, "rejected", "topic_unavailable"},
		{"duplicate capture", "DuplicateCapture", 20, 10, "rejected", "exists"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			e := newSyncEnv(t)
			topicID, itemID := uuid.NewString(), uuid.NewString()
			e.push(phoneID,
				op{"type": "CreateTopic", "at": e.at(0), "topic_id": topicID, "name": "Work"},
				op{"type": "CaptureItem", "at": e.at(10), "topic_id": topicID, "item_id": itemID, "text": "original"})
			if tc.kind == "MoveItem" {
				itemID = uuid.NewString()
				e.push(phoneID, op{"type": "CaptureItem", "at": e.at(1), "item_id": itemID, "text": "incoming"})
			}
			if tc.kind == "RestoreItem" {
				e.push(phoneID, op{"type": "TrashItem", "at": e.at(15), "item_id": itemID})
			}
			if tc.kind == "RedirectCapture" || tc.kind == "RejectedMove" {
				e.push(phoneID, op{"type": "DeleteTopic", "at": e.at(15), "topic_id": topicID})
			}
			cursor := e.pull(0).Cursor
			o := op{"type": tc.kind, "at": e.at(tc.at), "topic_id": topicID, "item_id": itemID, "text": "new", "base_rev": 0, "name": "Renamed"}
			switch tc.kind {
			case "CaptureItem", "RedirectCapture":
				o["type"] = "CaptureItem"
				o["item_id"] = uuid.NewString()
			case "DuplicateCapture":
				o["type"] = "CaptureItem"
			case "RejectedMove":
				o["type"] = "MoveItem"
			case "MoveOut":
				o["type"] = "MoveItem"
				delete(o, "topic_id")
			}
			res := e.push(phoneID, o)[0]
			if res.Status != tc.status || res.Reason != tc.reason {
				t.Fatalf("result = %+v, want %s/%s", res, tc.status, tc.reason)
			}
			want := syncBase.Add(time.Duration(tc.want) * time.Minute)
			if got := e.topic(topicID).ActivityAt; !got.Equal(want) {
				t.Errorf("activity_at = %v, want %v", got, want)
			}
			page := e.pull(cursor)
			changed := tc.want > 10 || tc.kind == "RenameTopic" || tc.status == "rejected"
			if got := len(page.Topics); (got == 1) != changed {
				t.Errorf("incremental pull has %d Topics, want changed=%v", got, changed)
			}
			if tc.kind == "RedirectCapture" && e.item(o["item_id"].(string)).TopicID != nil {
				t.Error("redirected capture did not reach Inbox")
			}
		})
	}
}

func TestTopicActivityFutureTimeClamped(t *testing.T) {
	e := newSyncEnv(t)
	id := uuid.NewString()
	for _, kind := range []string{"CreateTopic", "CaptureItem", "MoveItem"} {
		o := op{"type": kind, "at": e.at(3 * 24 * 60), "topic_id": id, "name": "Work", "item_id": uuid.NewString(), "text": "incoming"}
		if kind == "MoveItem" {
			e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": o["item_id"], "text": "inbox"})
		}
		if res := e.push(phoneID, o)[0]; res.Status != "accepted" {
			t.Fatalf("%s: %+v", kind, res)
		}
		if got := e.topic(id).ActivityAt; !got.Equal(e.clock.Now()) {
			t.Errorf("%s activity = %v, want Server now %v", kind, got, e.clock.Now())
		}
		e.clock.Advance(time.Minute)
	}
}
