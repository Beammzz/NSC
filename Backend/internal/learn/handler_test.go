package learn

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/auth"
)

// testServer wires the learn handler behind the real JWT middleware stack,
// mirroring cmd/server/main.go, and returns ready Bearer tokens.
func testServer(t *testing.T) (srv *httptest.Server, userToken, adminToken string, store *Store) {
	t.Helper()
	store = testStore(t)
	if err := Seed(store); err != nil {
		t.Fatalf("seeding: %v", err)
	}

	secret, err := auth.GenerateRandomSecret()
	if err != nil {
		t.Fatalf("generating secret: %v", err)
	}
	requireAuth := auth.RequireAuth(secret)
	adminMW := func(next http.Handler) http.Handler {
		return requireAuth(auth.RequireRole(auth.RoleAdmin)(next))
	}

	mux := http.NewServeMux()
	NewHandler(store).RegisterProtected(mux, requireAuth, adminMW)
	srv = httptest.NewServer(mux)
	t.Cleanup(srv.Close)

	userToken, err = auth.GenerateAccessToken(7, "user@test", auth.RoleUser, secret)
	if err != nil {
		t.Fatalf("generating user token: %v", err)
	}
	adminToken, err = auth.GenerateAccessToken(1, "admin@test", auth.RoleAdmin, secret)
	if err != nil {
		t.Fatalf("generating admin token: %v", err)
	}
	return srv, userToken, adminToken, store
}

func doJSON(t *testing.T, method, url, token, body string) *http.Response {
	t.Helper()
	var reader *strings.Reader
	if body == "" {
		reader = strings.NewReader("")
	} else {
		reader = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, url, reader)
	if err != nil {
		t.Fatalf("building request: %v", err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, url, err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func TestAuthRequired(t *testing.T) {
	srv, userToken, _, _ := testServer(t)

	if resp := doJSON(t, "GET", srv.URL+"/api/v1/learn/topics", "", ""); resp.StatusCode != http.StatusUnauthorized {
		t.Errorf("no token: status = %d, want 401", resp.StatusCode)
	}
	// Non-admin cannot reach admin CRUD.
	if resp := doJSON(t, "GET", srv.URL+"/api/v1/admin/learn/topics", userToken, ""); resp.StatusCode != http.StatusForbidden {
		t.Errorf("user on admin route: status = %d, want 403", resp.StatusCode)
	}
}

func TestTopicsAndDictionary(t *testing.T) {
	srv, userToken, _, _ := testServer(t)

	resp := doJSON(t, "GET", srv.URL+"/api/v1/learn/topics", userToken, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("topics: status = %d, want 200", resp.StatusCode)
	}
	var topicsBody struct {
		Topics []Topic `json:"topics"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&topicsBody); err != nil {
		t.Fatalf("decoding topics: %v", err)
	}
	if len(topicsBody.Topics) != len(seedTopics) {
		t.Errorf("topics = %d, want %d", len(topicsBody.Topics), len(seedTopics))
	}

	resp = doJSON(t, "GET", srv.URL+"/api/v1/learn/dictionary", userToken, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("dictionary: status = %d, want 200", resp.StatusCode)
	}
	var dictBody struct {
		Signs []Sign `json:"signs"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&dictBody); err != nil {
		t.Fatalf("decoding dictionary: %v", err)
	}
	if len(dictBody.Signs) != 150 {
		t.Errorf("signs = %d, want 150", len(dictBody.Signs))
	}

	// Thai word in the path segment.
	resp = doJSON(t, "GET", srv.URL+"/api/v1/learn/dictionary/กิน", userToken, "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("dictionary entry: status = %d, want 200", resp.StatusCode)
	}
	resp = doJSON(t, "GET", srv.URL+"/api/v1/learn/dictionary/ไม่มีคำนี้", userToken, "")
	if resp.StatusCode != http.StatusNotFound {
		t.Errorf("missing entry: status = %d, want 404", resp.StatusCode)
	}
}

func TestProgressRoundTrip(t *testing.T) {
	srv, userToken, _, store := testServer(t)
	topics, _ := store.ListTopics(true)
	ex := topics[0].Exercises[0]

	resp := doJSON(t, "POST", srv.URL+"/api/v1/learn/progress", userToken,
		`{"exercise_id": `+jsonInt(ex.ID)+`, "confidence": 0.92}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("recording attempt: status = %d, want 200", resp.StatusCode)
	}
	var p Progress
	if err := json.NewDecoder(resp.Body).Decode(&p); err != nil {
		t.Fatalf("decoding progress: %v", err)
	}
	if !p.Passed {
		t.Errorf("0.92 vs threshold 0.8: passed = false, want true")
	}

	resp = doJSON(t, "GET", srv.URL+"/api/v1/learn/progress", userToken, "")
	var listBody struct {
		Progress []Progress `json:"progress"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&listBody); err != nil {
		t.Fatalf("decoding progress list: %v", err)
	}
	if len(listBody.Progress) != 1 {
		t.Errorf("progress rows = %d, want 1", len(listBody.Progress))
	}

	// Out-of-range confidence rejected.
	resp = doJSON(t, "POST", srv.URL+"/api/v1/learn/progress", userToken,
		`{"exercise_id": `+jsonInt(ex.ID)+`, "confidence": 1.5}`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("confidence 1.5: status = %d, want 400", resp.StatusCode)
	}
}

func TestAdminCRUD(t *testing.T) {
	srv, _, adminToken, _ := testServer(t)

	// Create topic.
	resp := doJSON(t, "POST", srv.URL+"/api/v1/admin/learn/topics", adminToken,
		`{"slug": "custom", "title": "หมวดใหม่", "icon": "⭐", "sort_order": 50, "published": false}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("creating topic: status = %d, want 200", resp.StatusCode)
	}
	var topic Topic
	if err := json.NewDecoder(resp.Body).Decode(&topic); err != nil {
		t.Fatalf("decoding topic: %v", err)
	}

	// Duplicate slug -> 409.
	resp = doJSON(t, "POST", srv.URL+"/api/v1/admin/learn/topics", adminToken,
		`{"slug": "custom", "title": "ซ้ำ"}`)
	if resp.StatusCode != http.StatusConflict {
		t.Errorf("duplicate slug: status = %d, want 409", resp.StatusCode)
	}

	// Create exercise with a custom threshold, then edit it (the admin flow
	// the user asked for: threshold editable in the webui).
	resp = doJSON(t, "POST", srv.URL+"/api/v1/admin/learn/exercises", adminToken,
		`{"topic_id": `+jsonInt(topic.ID)+`, "word": "กาแฟ", "pass_confidence": 0.7, "published": true}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("creating exercise: status = %d, want 200", resp.StatusCode)
	}
	var ex Exercise
	if err := json.NewDecoder(resp.Body).Decode(&ex); err != nil {
		t.Fatalf("decoding exercise: %v", err)
	}

	resp = doJSON(t, "PUT", srv.URL+"/api/v1/admin/learn/exercises/"+jsonInt(ex.ID), adminToken,
		`{"topic_id": `+jsonInt(topic.ID)+`, "word": "กาแฟ", "pass_confidence": 0.95, "published": true}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("updating exercise: status = %d, want 200", resp.StatusCode)
	}

	// Invalid threshold rejected.
	resp = doJSON(t, "PUT", srv.URL+"/api/v1/admin/learn/exercises/"+jsonInt(ex.ID), adminToken,
		`{"topic_id": `+jsonInt(topic.ID)+`, "word": "กาแฟ", "pass_confidence": 1.2}`)
	if resp.StatusCode != http.StatusBadRequest {
		t.Errorf("pass_confidence 1.2: status = %d, want 400", resp.StatusCode)
	}

	// Unpublished topic hidden from the app view but present for admin.
	resp = doJSON(t, "GET", srv.URL+"/api/v1/admin/learn/topics", adminToken, "")
	var adminBody struct {
		Topics []Topic `json:"topics"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&adminBody); err != nil {
		t.Fatalf("decoding admin topics: %v", err)
	}
	if len(adminBody.Topics) != len(seedTopics)+1 {
		t.Errorf("admin topics = %d, want %d", len(adminBody.Topics), len(seedTopics)+1)
	}

	// Delete exercise then topic.
	if resp := doJSON(t, "DELETE", srv.URL+"/api/v1/admin/learn/exercises/"+jsonInt(ex.ID), adminToken, ""); resp.StatusCode != http.StatusNoContent {
		t.Errorf("deleting exercise: status = %d, want 204", resp.StatusCode)
	}
	if resp := doJSON(t, "DELETE", srv.URL+"/api/v1/admin/learn/topics/"+jsonInt(topic.ID), adminToken, ""); resp.StatusCode != http.StatusNoContent {
		t.Errorf("deleting topic: status = %d, want 204", resp.StatusCode)
	}
	if resp := doJSON(t, "DELETE", srv.URL+"/api/v1/admin/learn/topics/"+jsonInt(topic.ID), adminToken, ""); resp.StatusCode != http.StatusNotFound {
		t.Errorf("double delete: status = %d, want 404", resp.StatusCode)
	}
}

func jsonInt(v int64) string {
	b, _ := json.Marshal(v)
	return string(b)
}
