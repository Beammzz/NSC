package stream

import (
	"context"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/llm"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

// fakeComposer records the word runs it is asked to compose and joins them
// the way llm.RawJoin would, without any network call.
type fakeComposer struct {
	policy llm.BufferPolicy

	mu    sync.Mutex
	calls [][]string
}

func (f *fakeComposer) Compose(ctx context.Context, words []string) llm.Result {
	f.mu.Lock()
	f.calls = append(f.calls, append([]string(nil), words...))
	f.mu.Unlock()
	return llm.Result{Sentence: strings.Join(words, ""), Fallback: true}
}

func (f *fakeComposer) Policy() llm.BufferPolicy { return f.policy }

func (f *fakeComposer) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func dialWithComposer(t *testing.T, ai AIClient, c SentenceComposer) (*websocket.Conn, func()) {
	t.Helper()
	srv := httptest.NewServer(NewHandler(ai, nil, c))
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		srv.Close()
		t.Fatalf("dialing test server: %v", err)
	}
	return conn, func() {
		conn.Close()
		srv.Close()
	}
}

// readUntilSentence drains prediction messages until a sentence arrives.
func readUntilSentence(t *testing.T, conn *websocket.Conn) map[string]any {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		msg := readServerMessage(t, conn)
		if msg["type"] == typeSentence {
			return msg
		}
	}
	t.Fatal("no sentence message arrived")
	return nil
}

func TestSilencePauseComposesTheBufferedWords(t *testing.T) {
	aiStream := newFakeAIStream()
	composer := &fakeComposer{policy: llm.BufferPolicy{Silence: 150 * time.Millisecond, MaxWords: 12}}
	conn, cleanup := dialWithComposer(t, &fakeAIClient{stream: aiStream}, composer)
	defer cleanup()
	readServerMessage(t, conn) // ready

	for _, word := range []string{"ฉัน", "รัก", "เธอ"} {
		aiStream.predictions <- &pb.Prediction{Word: word, Confidence: 0.9}
	}

	msg := readUntilSentence(t, conn)
	if msg["sentence"] != "ฉันรักเธอ" {
		t.Errorf("sentence = %v, want ฉันรักเธอ", msg["sentence"])
	}
	if msg["fallback"] != true {
		t.Errorf("fallback = %v, want true", msg["fallback"])
	}
	if composer.callCount() != 1 {
		t.Errorf("composer called %d times, want 1", composer.callCount())
	}
}

func TestRepeatedAndIdlePredictionsDoNotEnterTheSentence(t *testing.T) {
	aiStream := newFakeAIStream()
	composer := &fakeComposer{policy: llm.BufferPolicy{Silence: 150 * time.Millisecond, MaxWords: 12}}
	conn, cleanup := dialWithComposer(t, &fakeAIClient{stream: aiStream}, composer)
	defer cleanup()
	readServerMessage(t, conn) // ready

	// One gesture yields the same top-1 across several windows, framed by
	// idle and uncertain windows that carry no word.
	aiStream.predictions <- &pb.Prediction{IsIdle: true}
	aiStream.predictions <- &pb.Prediction{Word: "รัก", Confidence: 0.9}
	aiStream.predictions <- &pb.Prediction{Word: "รัก", Confidence: 0.9}
	aiStream.predictions <- &pb.Prediction{Word: "เธอ", Confidence: 0.4, IsUncertain: true}
	aiStream.predictions <- &pb.Prediction{IsIdle: true}

	msg := readUntilSentence(t, conn)
	if msg["sentence"] != "รัก" {
		t.Errorf("sentence = %v, want just รัก", msg["sentence"])
	}
	words, ok := msg["words"].([]any)
	if !ok || len(words) != 1 {
		t.Errorf("words = %v, want exactly one entry", msg["words"])
	}
}

func TestMaxWordsFlushesBeforeThePause(t *testing.T) {
	aiStream := newFakeAIStream()
	// An hour-long pause window: only the word cap can trigger this flush.
	composer := &fakeComposer{policy: llm.BufferPolicy{Silence: time.Hour, MaxWords: 2}}
	conn, cleanup := dialWithComposer(t, &fakeAIClient{stream: aiStream}, composer)
	defer cleanup()
	readServerMessage(t, conn) // ready

	aiStream.predictions <- &pb.Prediction{Word: "ฉัน", Confidence: 0.9}
	aiStream.predictions <- &pb.Prediction{Word: "รัก", Confidence: 0.9}

	msg := readUntilSentence(t, conn)
	if msg["sentence"] != "ฉันรัก" {
		t.Errorf("sentence = %v, want ฉันรัก", msg["sentence"])
	}
}

func TestResetDropsTheBufferWithoutComposing(t *testing.T) {
	aiStream := newFakeAIStream()
	composer := &fakeComposer{policy: llm.BufferPolicy{Silence: 200 * time.Millisecond, MaxWords: 12}}
	conn, cleanup := dialWithComposer(t, &fakeAIClient{stream: aiStream}, composer)
	defer cleanup()
	readServerMessage(t, conn) // ready

	aiStream.predictions <- &pb.Prediction{Word: "ฉัน", Confidence: 0.9}
	readServerMessage(t, conn) // the prediction, proving the word was observed

	if err := conn.WriteJSON(map[string]any{
		"schema_version": schemaVersion,
		"type":           typeReset,
	}); err != nil {
		t.Fatalf("sending reset: %v", err)
	}
	// The reset must reach the handler before the pause window elapses.
	select {
	case <-aiStream.sent:
	case <-time.After(2 * time.Second):
		t.Fatal("reset never reached the AI stream")
	}

	time.Sleep(400 * time.Millisecond)
	if got := composer.callCount(); got != 0 {
		t.Errorf("composer called %d times after a reset, want 0", got)
	}
}
