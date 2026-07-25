package llm

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// configure points the store at a stub endpoint and enables the service.
func configure(t *testing.T, store *Store, endpoint string) {
	t.Helper()
	enabled := true
	key := "sk-test"
	if _, err := store.SaveSettings(SettingsPatch{
		Enabled:  &enabled,
		APIKey:   &key,
		Endpoint: &endpoint,
	}); err != nil {
		t.Fatalf("SaveSettings: %v", err)
	}
}

// stubEndpoint replies with one assistant message and records the request.
func stubEndpoint(t *testing.T, content string) (*httptest.Server, *chatRequest, *string) {
	t.Helper()
	var got chatRequest
	var authHeader string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		authHeader = r.Header.Get("Authorization")
		body, _ := io.ReadAll(r.Body)
		if err := json.Unmarshal(body, &got); err != nil {
			t.Errorf("request body is not a chat request: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"choices":[{"message":{"role":"assistant","content":` +
			mustJSONString(content) + `}}]}`))
	}))
	t.Cleanup(srv.Close)
	return srv, &got, &authHeader
}

func mustJSONString(s string) string {
	b, err := json.Marshal(s)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func TestComposeReturnsFallbackWhenDisabled(t *testing.T) {
	store := openTemp(t)
	svc := NewService(store)

	got := svc.Compose(context.Background(), []string{"ฉัน", "รัก", "เธอ"})
	if got.Sentence != "ฉันรักเธอ" {
		t.Errorf("Sentence = %q, want the raw join ฉันรักเธอ", got.Sentence)
	}
	if !got.Fallback {
		t.Error("Fallback = false, want true when the service is disabled")
	}
	total, err := store.CountLogs()
	if err != nil {
		t.Fatalf("CountLogs: %v", err)
	}
	if total != 0 {
		t.Errorf("CountLogs = %d, want 0 — a disabled service makes no request to audit", total)
	}
}

func TestComposeUsesLLMSentenceAndLogsIt(t *testing.T) {
	store := openTemp(t)
	srv, req, auth := stubEndpoint(t, "ฉันรักเธอ")
	configure(t, store, srv.URL)
	svc := NewService(store)

	got := svc.Compose(context.Background(), []string{"ฉัน", "รัก", "เธอ"})
	if got.Fallback {
		t.Errorf("Fallback = true, want false; error was %q", got.Error)
	}
	if got.Sentence != "ฉันรักเธอ" {
		t.Errorf("Sentence = %q, want ฉันรักเธอ", got.Sentence)
	}
	if *auth != "Bearer sk-test" {
		t.Errorf("Authorization = %q, want Bearer sk-test", *auth)
	}
	if req.Model != DefaultModel {
		t.Errorf("request model = %q, want %q", req.Model, DefaultModel)
	}
	if len(req.Messages) != 2 || req.Messages[0].Role != "system" {
		t.Fatalf("messages = %+v, want a system message then the glosses", req.Messages)
	}
	if req.Messages[1].Content != "ฉัน รัก เธอ" {
		t.Errorf("user message = %q, want the space-separated glosses", req.Messages[1].Content)
	}

	logs, err := store.ListLogs(QueryOptions{})
	if err != nil {
		t.Fatalf("ListLogs: %v", err)
	}
	if len(logs) != 1 {
		t.Fatalf("ListLogs returned %d records, want 1", len(logs))
	}
	if !logs[0].OK || logs[0].Fallback {
		t.Errorf("logged ok=%v fallback=%v, want ok=true fallback=false", logs[0].OK, logs[0].Fallback)
	}
}

func TestComposeFallsBackOnEndpointError(t *testing.T) {
	store := openTemp(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "upstream exploded", http.StatusInternalServerError)
	}))
	t.Cleanup(srv.Close)
	configure(t, store, srv.URL)
	svc := NewService(store)

	got := svc.Compose(context.Background(), []string{"ฉัน", "รัก", "เธอ"})
	if !got.Fallback {
		t.Error("Fallback = false, want true after a 500")
	}
	if got.Sentence != "ฉันรักเธอ" {
		t.Errorf("Sentence = %q, want the raw join", got.Sentence)
	}
	if !strings.Contains(got.Error, "500") {
		t.Errorf("Error = %q, want it to name the 500 status", got.Error)
	}
	logs, err := store.ListLogs(QueryOptions{})
	if err != nil {
		t.Fatalf("ListLogs: %v", err)
	}
	if len(logs) != 1 || logs[0].OK {
		t.Errorf("want one failed log entry, got %+v", logs)
	}
}

func TestComposeRejectsSentenceThatDropsAWord(t *testing.T) {
	store := openTemp(t)
	// "เธอ" is missing: the model rewrote what the signer said.
	srv, _, _ := stubEndpoint(t, "ฉันรัก")
	configure(t, store, srv.URL)
	svc := NewService(store)

	got := svc.Compose(context.Background(), []string{"ฉัน", "รัก", "เธอ"})
	if !got.Fallback {
		t.Error("Fallback = false, want true when a recognized word disappears")
	}
	if got.Sentence != "ฉันรักเธอ" {
		t.Errorf("Sentence = %q, want the raw join", got.Sentence)
	}
}

func TestValidateCleansModelFormatting(t *testing.T) {
	words := []string{"ฉัน", "รัก", "เธอ"}
	cases := []struct {
		name string
		raw  string
		want string
	}{
		{"plain", "ฉันรักเธอ", "ฉันรักเธอ"},
		{"surrounding whitespace", "  ฉันรักเธอ\n", "ฉันรักเธอ"},
		{"double quoted", `"ฉันรักเธอ"`, "ฉันรักเธอ"},
		{"curly quoted", "“ฉันรักเธอ”", "ฉันรักเธอ"},
		{"code fence", "```\nฉันรักเธอ\n```", "ฉันรักเธอ"},
		{"explanation on later lines", "ฉันรักเธอ\nคำอธิบาย: ...", "ฉันรักเธอ"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := validate(tc.raw, words)
			if err != nil {
				t.Fatalf("validate(%q): %v", tc.raw, err)
			}
			if got != tc.want {
				t.Errorf("validate(%q) = %q, want %q", tc.raw, got, tc.want)
			}
		})
	}
}

func TestValidateRejectsBadOutput(t *testing.T) {
	words := []string{"ฉัน", "รัก", "เธอ"}
	cases := []struct {
		name string
		raw  string
	}{
		{"empty", "   "},
		{"dropped word", "ฉันรัก"},
		{"runaway explanation", strings.Repeat("ฉันรักเธอ", 40)},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got, err := validate(tc.raw, words); err == nil {
				t.Errorf("validate(%q) = %q, want an error", tc.raw, got)
			}
		})
	}
}

func TestPolicyReflectsSavedSettings(t *testing.T) {
	store := openTemp(t)
	svc := NewService(store)

	if got := svc.Policy(); got.Silence.Milliseconds() != DefaultSilenceMS {
		t.Errorf("Policy().Silence = %v, want the %dms default", got.Silence, DefaultSilenceMS)
	}

	silence := 3500
	maxWords := 5
	if _, err := store.SaveSettings(SettingsPatch{SilenceMS: &silence, MaxWords: &maxWords}); err != nil {
		t.Fatalf("SaveSettings: %v", err)
	}
	policy := svc.Policy()
	if policy.Silence.Milliseconds() != 3500 {
		t.Errorf("Policy().Silence = %v, want 3500ms", policy.Silence)
	}
	if policy.MaxWords != 5 {
		t.Errorf("Policy().MaxWords = %d, want 5", policy.MaxWords)
	}
}
