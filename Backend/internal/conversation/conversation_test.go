package conversation_test

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/conversation"
)

func TestConversationHandler_ValidPOST(t *testing.T) {
	// The "โรงพยาบาลอยู่ที่ไหน" message yields gloss "โรงพยาบาล ตรง ขวา";
	// recording all three words keeps keypoint_transitions non-empty.
	handler := conversation.Handler(fakeLookup(map[string][][]conversation.LandmarkPoint{
		"โรงพยาบาล": makeFrames(2, 0.10),
		"ตรง":       makeFrames(2, 0.20),
		"ขวา":       makeFrames(2, 0.30),
	}))

	payload := map[string]string{
		"message": "โรงพยาบาลอยู่ที่ไหน",
		"locale":  "th-TH",
	}
	body, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal error: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/v1/conversation", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}

	var resp conversation.Response
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode error: %v", err)
	}

	if resp.ReplyText == "" {
		t.Errorf("expected non-empty reply_text")
	}
	if resp.ReplySignGloss == "" {
		t.Errorf("expected non-empty reply_sign_gloss")
	}
	if len(resp.KeypointTransitions) == 0 {
		t.Errorf("expected non-empty keypoint_transitions")
	}
}

func TestConversationHandler_InvalidMethod(t *testing.T) {
	handler := conversation.Handler(nil)
	req := httptest.NewRequest(http.MethodGet, "/api/v1/conversation", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected status 405, got %d", rec.Code)
	}
}

func TestConversationHandler_EmptyMessage(t *testing.T) {
	handler := conversation.Handler(nil)
	body := []byte(`{"message": "   "}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/conversation", bytes.NewReader(body))
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected status 400, got %d", rec.Code)
	}
}

// TestConversationHandler_StitchesGlossFrames checks the reply's avatar is
// concatenated from the recorded words, a rest hold separates the signs, and
// words without a recording are skipped.
func TestConversationHandler_StitchesGlossFrames(t *testing.T) {
	// A non-keyword message yields the default gloss "สวัสดี พบ ยินดี".
	// Two words are recorded; "พบ" is missing and must be skipped.
	sawat := makeFrames(2, 0.10)
	yindi := makeFrames(3, 0.20)
	handler := conversation.Handler(fakeLookup(map[string][][]conversation.LandmarkPoint{
		"สวัสดี": sawat,
		"ยินดี":  yindi,
	}))

	resp := postMessage(t, handler, "หวัดดี")
	if resp.ReplySignGloss != "สวัสดี พบ ยินดี" {
		t.Fatalf("unexpected gloss %q", resp.ReplySignGloss)
	}

	// สวัสดี(2) + rest hold(3) + ยินดี(3) = 8; "พบ" contributes nothing.
	const restGap = 3
	want := len(sawat) + restGap + len(yindi)
	if got := len(resp.KeypointTransitions); got != want {
		t.Fatalf("stitched frame count = %d, want %d", got, want)
	}
	// The gap holds สวัสดี's final frame before ยินดี begins.
	last := sawat[len(sawat)-1]
	gap := resp.KeypointTransitions[len(sawat)]
	if len(gap) != len(last) || gap[0].X != last[0].X {
		t.Errorf("gap frame did not hold previous sign's last frame: got %+v", gap)
	}
	// The final recorded frame is ยินดี's last (raw coords preserved).
	end := resp.KeypointTransitions[want-1]
	if end[0].X != yindi[len(yindi)-1][0].X {
		t.Errorf("sequence did not end on ยินดี's last frame")
	}
}

// TestConversationHandler_NoRecordingsEmptyTransitions documents that with no
// recorded words the transitions are empty — the client renders the procedural
// avatar rather than a broken sequence.
func TestConversationHandler_NoRecordingsEmptyTransitions(t *testing.T) {
	handler := conversation.Handler(fakeLookup(nil))
	resp := postMessage(t, handler, "หวัดดี")
	if len(resp.KeypointTransitions) != 0 {
		t.Fatalf("expected empty transitions, got %d frames", len(resp.KeypointTransitions))
	}
}

// postMessage POSTs a conversation message and decodes the 200 response.
func postMessage(t *testing.T, handler http.HandlerFunc, message string) conversation.Response {
	t.Helper()
	body, err := json.Marshal(map[string]string{"message": message})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/api/v1/conversation", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected status 200, got %d", rec.Code)
	}
	var resp conversation.Response
	if err := json.NewDecoder(rec.Body).Decode(&resp); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return resp
}

// fakeLookup builds a conversation.KeypointLookup from an in-memory word->frames
// map, marshalling each entry as the store would return it (json.RawMessage).
func fakeLookup(byWord map[string][][]conversation.LandmarkPoint) conversation.KeypointLookup {
	return func(word string) (json.RawMessage, bool) {
		frames, ok := byWord[word]
		if !ok {
			return nil, false
		}
		raw, err := json.Marshal(frames)
		if err != nil {
			return nil, false
		}
		return raw, true
	}
}

// makeFrames builds n distinguishable 7-point frames; base offsets the X of
// each point so frames from different words are identifiable in assertions.
func makeFrames(n int, base float64) [][]conversation.LandmarkPoint {
	frames := make([][]conversation.LandmarkPoint, n)
	for i := range frames {
		pts := make([]conversation.LandmarkPoint, 7)
		for j := range pts {
			pts[j] = conversation.LandmarkPoint{
				X: base + float64(i)*0.01 + float64(j)*0.001,
				Y: 0.5,
				Z: 0,
			}
		}
		frames[i] = pts
	}
	return frames
}
