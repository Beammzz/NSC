package stream

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

type fakeAIStream struct {
	sent        chan *pb.LandmarkFrame
	predictions chan *pb.Prediction
	closed      chan struct{}
}

func newFakeAIStream() *fakeAIStream {
	return &fakeAIStream{
		sent:        make(chan *pb.LandmarkFrame, 16),
		predictions: make(chan *pb.Prediction, 16),
		closed:      make(chan struct{}),
	}
}

func (f *fakeAIStream) Send(frame *pb.LandmarkFrame) error {
	f.sent <- frame
	return nil
}

func (f *fakeAIStream) Recv() (*pb.Prediction, error) {
	select {
	case p := <-f.predictions:
		return p, nil
	case <-f.closed:
		return nil, io.EOF
	}
}

func (f *fakeAIStream) CloseSend() error {
	select {
	case <-f.closed:
	default:
		close(f.closed)
	}
	return nil
}

type fakeAIClient struct {
	stream  *fakeAIStream
	openErr error
}

func (f *fakeAIClient) OpenStream(ctx context.Context) (AIStream, error) {
	if f.openErr != nil {
		return nil, f.openErr
	}
	return f.stream, nil
}

func dialTestServer(t *testing.T, ai AIClient) (*websocket.Conn, func()) {
	t.Helper()
	srv := httptest.NewServer(NewHandler(ai, nil))
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

func readServerMessage(t *testing.T, conn *websocket.Conn) map[string]any {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	_, data, err := conn.ReadMessage()
	if err != nil {
		t.Fatalf("reading server message: %v", err)
	}
	var msg map[string]any
	if err := json.Unmarshal(data, &msg); err != nil {
		t.Fatalf("decoding server message %q: %v", data, err)
	}
	return msg
}

func validFrame(seq int) map[string]any {
	features := make([]float32, featureDim)
	return map[string]any{
		"schema_version": schemaVersion,
		"type":           typeLandmarkFrame,
		"seq":            seq,
		"timestamp_ms":   1720252800000,
		"features":       features,
	}
}

func TestStreamRoundTrip(t *testing.T) {
	aiStream := newFakeAIStream()
	conn, cleanup := dialTestServer(t, &fakeAIClient{stream: aiStream})
	defer cleanup()

	if msg := readServerMessage(t, conn); msg["type"] != typeReady {
		t.Fatalf("expected ready message first, got %v", msg)
	}

	if err := conn.WriteJSON(validFrame(7)); err != nil {
		t.Fatalf("sending frame: %v", err)
	}
	select {
	case frame := <-aiStream.sent:
		if frame.GetSeq() != 7 || len(frame.GetFeatures()) != featureDim {
			t.Fatalf("forwarded frame mismatch: seq=%d features=%d",
				frame.GetSeq(), len(frame.GetFeatures()))
		}
	case <-time.After(5 * time.Second):
		t.Fatal("frame never reached the AI stream")
	}

	aiStream.predictions <- &pb.Prediction{
		Seq:        7,
		Word:       "สวัสดี",
		Confidence: 0.94,
		Top:        []*pb.ClassProb{{Label: "สวัสดี", Prob: 0.94}},
	}
	msg := readServerMessage(t, conn)
	if msg["type"] != typePrediction || msg["word"] != "สวัสดี" {
		t.Fatalf("expected prediction for สวัสดี, got %v", msg)
	}
	if msg["schema_version"] != float64(schemaVersion) {
		t.Fatalf("prediction missing schema_version: %v", msg)
	}
}

func TestResetForwarded(t *testing.T) {
	aiStream := newFakeAIStream()
	conn, cleanup := dialTestServer(t, &fakeAIClient{stream: aiStream})
	defer cleanup()
	readServerMessage(t, conn) // ready

	if err := conn.WriteJSON(map[string]any{
		"schema_version": schemaVersion,
		"type":           typeReset,
	}); err != nil {
		t.Fatalf("sending reset: %v", err)
	}
	select {
	case frame := <-aiStream.sent:
		if !frame.GetReset_() {
			t.Fatalf("expected reset frame, got %v", frame)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("reset never reached the AI stream")
	}
}

func TestInvalidFeatureDimKeepsConnection(t *testing.T) {
	aiStream := newFakeAIStream()
	conn, cleanup := dialTestServer(t, &fakeAIClient{stream: aiStream})
	defer cleanup()
	readServerMessage(t, conn) // ready

	bad := validFrame(1)
	bad["features"] = []float32{1, 2, 3}
	if err := conn.WriteJSON(bad); err != nil {
		t.Fatalf("sending bad frame: %v", err)
	}
	msg := readServerMessage(t, conn)
	if msg["type"] != typeError {
		t.Fatalf("expected error message, got %v", msg)
	}
	problem := msg["problem"].(map[string]any)
	if problem["status"] != float64(http.StatusBadRequest) {
		t.Fatalf("expected 400 problem, got %v", problem)
	}

	// Connection survives: a valid frame still goes through.
	if err := conn.WriteJSON(validFrame(2)); err != nil {
		t.Fatalf("sending valid frame after error: %v", err)
	}
	select {
	case <-aiStream.sent:
	case <-time.After(5 * time.Second):
		t.Fatal("valid frame after error never forwarded")
	}
}

func TestUnsupportedSchemaVersionCloses(t *testing.T) {
	aiStream := newFakeAIStream()
	conn, cleanup := dialTestServer(t, &fakeAIClient{stream: aiStream})
	defer cleanup()
	readServerMessage(t, conn) // ready

	frame := validFrame(1)
	frame["schema_version"] = 99
	if err := conn.WriteJSON(frame); err != nil {
		t.Fatalf("sending frame: %v", err)
	}
	msg := readServerMessage(t, conn)
	if msg["type"] != typeError {
		t.Fatalf("expected error message, got %v", msg)
	}

	// The server tears the session down afterwards.
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	for {
		if _, _, err := conn.ReadMessage(); err != nil {
			return
		}
	}
}

func TestPredictionsReachRecorder(t *testing.T) {
	aiStream := newFakeAIStream()
	recorded := make(chan *pb.Prediction, 1)
	srv := httptest.NewServer(NewHandler(&fakeAIClient{stream: aiStream},
		func(p *pb.Prediction) { recorded <- p }))
	defer srv.Close()
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http")
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dialing test server: %v", err)
	}
	defer conn.Close()
	readServerMessage(t, conn) // ready

	aiStream.predictions <- &pb.Prediction{Seq: 3, Word: "รัก", Confidence: 0.8}
	select {
	case p := <-recorded:
		if p.GetSeq() != 3 || p.GetWord() != "รัก" {
			t.Fatalf("recorded prediction mismatch: %v", p)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("prediction never reached the recorder")
	}
}

func TestAIUnavailableReturnsProblem(t *testing.T) {
	srv := httptest.NewServer(NewHandler(&fakeAIClient{openErr: errors.New("ai down")}, nil))
	defer srv.Close()

	resp, err := http.Get(srv.URL)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("expected 503, got %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("expected problem+json, got %s", ct)
	}
}
