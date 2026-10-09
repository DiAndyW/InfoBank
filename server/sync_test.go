package server

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/google/uuid"
)

// Device ids are fixed so tie-breaks are predictable: phone < desktop.
const (
	phoneID   = "00000000-0000-4000-8000-000000000001"
	desktopID = "00000000-0000-4000-8000-000000000002"
)

type syncEnv struct {
	t     *testing.T
	h     http.Handler
	clock *testClock
}

func newSyncEnv(t *testing.T) *syncEnv {
	t.Helper()
	db := openPool(t, newTestDatabase(t))
	if err := Migrate(context.Background(), db); err != nil {
		t.Fatal(err)
	}
	// A day after at(0), so tests' Device timestamps are in the past unless a test means otherwise.
	clock := &testClock{now: syncBase.Add(24 * time.Hour)}
	h, err := New(Config{Secret: testSecret, Now: clock.Now, DB: db, AttachmentDir: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	return &syncEnv{t: t, h: h, clock: clock}
}

var syncBase = time.Date(2026, 10, 4, 12, 0, 0, 0, time.UTC)

// at is a Device timestamp minutes after syncBase.
func (e *syncEnv) at(minutes int) string {
	return syncBase.Add(time.Duration(minutes) * time.Minute).Format(time.RFC3339Nano)
}

type op map[string]any

type pushResult struct {
	OpID   string `json:"op_id"`
	Status string `json:"status"`
	Reason string `json:"reason"`
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
	Text        *string            `json:"text"`
	CaptureTime time.Time          `json:"capture_time"`
	DeletedAt   *time.Time         `json:"deleted_at"`
	Attachments []pulledAttachment `json:"attachments"`
}

type pulledTopic struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	ArchivedAt *time.Time `json:"archived_at"`
	DeletedAt  *time.Time `json:"deleted_at"`
}

type pullPage struct {
	Items   []pulledItem  `json:"items"`
	Topics  []pulledTopic `json:"topics"`
	Cursor  int64         `json:"cursor"`
	HasMore bool          `json:"has_more"`
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
		op{"type": "ArchiveTopic", "at": e.at(1), "topic_id": topicID},
		op{"type": "CaptureItem", "at": "2026-10-04T05:00:00-07:00", "item_id": itemID, "text": "x"},
		op{"type": "TrashItem", "at": e.at(2), "item_id": itemID})

	var page struct {
		Items  []map[string]any
		Topics []map[string]any
	}
	if err := json.Unmarshal(e.do("GET", "/sync/pull?cursor=0", nil).Body.Bytes(), &page); err != nil {
		t.Fatal(err)
	}
	got := []any{page.Items[0]["capture_time"], page.Items[0]["deleted_at"], page.Topics[0]["archived_at"]}
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

func topicOf(it pulledItem) string {
	if it.TopicID == nil {
		return "Inbox"
	}
	return *it.TopicID
}

func TestCaptureIntoATopicArchivedMeanwhileLandsInInbox(t *testing.T) {
	e := newSyncEnv(t)
	gym, itemID := uuid.NewString(), uuid.NewString()
	e.push(desktopID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"})

	// The phone captures into Gym offline; the desktop archives Gym before the phone syncs.
	e.push(desktopID, op{"type": "ArchiveTopic", "at": e.at(10), "topic_id": gym})
	res := e.push(phoneID, op{"type": "CaptureItem", "at": e.at(5), "item_id": itemID, "topic_id": gym, "text": "squat 100"})

	if res[0].Status != "changed" || res[0].Reason != "sent_to_inbox" {
		t.Errorf("capture result = %+v, want changed sent_to_inbox", res[0])
	}
	if got := topicOf(e.item(itemID)); got != "Inbox" {
		t.Fatalf("Item is in %s, want Inbox", got)
	}
	if e.topic(gym).ArchivedAt == nil {
		t.Fatalf("Gym not archived")
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

func TestMoveIntoAnArchivedTopicIsRejectedUntilUnarchived(t *testing.T) {
	e := newSyncEnv(t)
	gym, itemID := uuid.NewString(), uuid.NewString()
	e.push(desktopID,
		op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"},
		op{"type": "ArchiveTopic", "at": e.at(1), "topic_id": gym},
		op{"type": "CaptureItem", "at": e.at(2), "item_id": itemID, "text": "squat 100"})

	res := e.push(phoneID, op{"type": "MoveItem", "at": e.at(3), "item_id": itemID, "topic_id": gym})
	if res[0].Status != "rejected" || res[0].Reason != "topic_unavailable" || topicOf(e.item(itemID)) != "Inbox" {
		t.Fatalf("move into archived Topic: result %+v; want rejected topic_unavailable, Item stays in Inbox", res[0])
	}

	e.push(desktopID, op{"type": "UnarchiveTopic", "at": e.at(4), "topic_id": gym})
	res = e.push(phoneID, op{"type": "MoveItem", "at": e.at(5), "item_id": itemID, "topic_id": gym})
	if res[0].Status != "accepted" || topicOf(e.item(itemID)) != gym {
		t.Fatalf("move after unarchive: result %+v, Item in %s; want accepted, in Gym", res[0], topicOf(e.item(itemID)))
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

func TestLaterArchiveStateWins(t *testing.T) {
	e := newSyncEnv(t)
	gym := uuid.NewString()
	e.push(desktopID, op{"type": "CreateTopic", "at": e.at(0), "topic_id": gym, "name": "Gym"})

	e.push(desktopID, op{"type": "ArchiveTopic", "at": e.at(10), "topic_id": gym})
	late := e.push(phoneID, op{"type": "UnarchiveTopic", "at": e.at(5), "topic_id": gym})

	if late[0].Reason != "superseded" || e.topic(gym).ArchivedAt == nil {
		t.Fatalf("older unarchive: result %+v; want superseded, Gym still archived", late[0])
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
				e.push(phoneID, op{"type": "SetText", "at": e.at(c.editAt), "item_id": itemID, "text": "edited"})
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
	if e.item(itemID).DeletedAt != nil {
		t.Fatalf("Item still in Trash after a later restore")
	}
}

func TestItemEmptiedByTwoDevicesGoesToTrashAndCannotBeRestored(t *testing.T) {
	e := newSyncEnv(t)
	itemID := uuid.NewString()
	p := newAttachment("P.jpg")
	e.push(phoneID, op{"type": "CaptureItem", "at": e.at(0), "item_id": itemID, "text": "caption", "attachments": []any{p}})

	// Each Device leaves something behind locally; together they leave nothing.
	e.push(desktopID, op{"type": "SetText", "at": e.at(10), "item_id": itemID, "text": nil})
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
		{"type": "ArchiveTopic", "at": e.at(20), "topic_id": gym},
		{"type": "DeleteTopic", "at": e.at(20), "topic_id": gym, "trash": []string{}},
	} {
		if res := e.push(phoneID, o); res[0].Reason != "topic_deleted" {
			t.Errorf("%s after delete = %+v, want rejected topic_deleted", o["type"], res[0])
		}
	}
	if tp := e.topic(gym); tp.Name != "Gym" || tp.ArchivedAt != nil {
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
		"edit unknown item":            {op{"type": "SetText", "at": e.at(1), "item_id": uuid.NewString(), "text": "x"}, "not_found"},
		"unknown op type":              {op{"type": "Explode", "at": e.at(1)}, "invalid"},
		"timestamp that doesn't parse": {op{"type": "SetText", "at": "yesterday", "item_id": itemID, "text": "x"}, "invalid"},
		"missing op id":                {op{"id": "", "type": "SetText", "at": e.at(1), "item_id": itemID, "text": "x"}, "invalid"},
	}
	for name, c := range cases {
		// A good op after the bad one must still apply: one bad op never blocks the queue.
		res := e.push(phoneID, c.o, op{"type": "SetText", "at": e.at(2), "item_id": itemID, "text": name})
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

	e.push(desktopID, op{"type": "SetText", "at": e.at(10), "item_id": itemID, "text": "desktop at 10"})
	late := e.push(phoneID, op{"type": "SetText", "at": e.at(5), "item_id": itemID, "text": "phone at 5"})

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

	e.push(desktopID, op{"type": "SetText", "at": e.at(10), "item_id": first, "text": "desktop"})
	e.push(phoneID, op{"type": "SetText", "at": e.at(10), "item_id": first, "text": "phone"})
	e.push(phoneID, op{"type": "SetText", "at": e.at(10), "item_id": second, "text": "phone"})
	e.push(desktopID, op{"type": "SetText", "at": e.at(10), "item_id": second, "text": "desktop"})

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
		op{"type": "SetText", "at": e.at(0), "item_id": itemID, "text": "ab"})
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
	e.push(phoneID, op{"type": "SetText", "at": e.at(2 * day), "item_id": itemID, "text": "phone, clock a day fast"})
	e.clock.Advance(5 * time.Minute)
	e.push(desktopID, op{"type": "SetText", "at": e.at(day + 2), "item_id": itemID, "text": "desktop, 2 minutes later"})

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
