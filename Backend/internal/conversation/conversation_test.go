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
	handler := conversation.Handler()

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
	handler := conversation.Handler()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/conversation", nil)
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusMethodNotAllowed {
		t.Fatalf("expected status 405, got %d", rec.Code)
	}
}

func TestConversationHandler_EmptyMessage(t *testing.T) {
	handler := conversation.Handler()
	body := []byte(`{"message": "   "}`)
	req := httptest.NewRequest(http.MethodPost, "/api/v1/conversation", bytes.NewReader(body))
	rec := httptest.NewRecorder()

	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected status 400, got %d", rec.Code)
	}
}
