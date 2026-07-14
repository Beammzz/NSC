package admin

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/config"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/predlog"
)

// ---- fakes (only the methods the admin handler calls are implemented; the
// embedded nil interfaces cover the rest of the generated surface) ----

type fakeUploadStream struct {
	grpc.ClientStream
	requests []*pb.UploadModelRequest
	response *pb.UploadModelResponse
	err      error
}

func (f *fakeUploadStream) Send(r *pb.UploadModelRequest) error {
	f.requests = append(f.requests, proto.Clone(r).(*pb.UploadModelRequest))
	return nil
}

func (f *fakeUploadStream) CloseAndRecv() (*pb.UploadModelResponse, error) {
	return f.response, f.err
}

type fakeLogStream struct {
	grpc.ClientStream
	entries []*pb.LogEntry
	next    int
}

func (f *fakeLogStream) Recv() (*pb.LogEntry, error) {
	if f.next >= len(f.entries) {
		return nil, io.EOF
	}
	entry := f.entries[f.next]
	f.next++
	return entry, nil
}

type fakeAI struct {
	pb.TslInferenceClient // nil: StreamInference is never called here
	tuning                *pb.TuningState
	tuningErr             error
	setRequests           []*pb.SetTuningRequest
	upload                *fakeUploadStream
	logEntries            []*pb.LogEntry
	logRequest            *pb.StreamLogsRequest
}

func (f *fakeAI) GetTuning(ctx context.Context, in *pb.GetTuningRequest, opts ...grpc.CallOption) (*pb.TuningState, error) {
	return f.tuning, f.tuningErr
}

func (f *fakeAI) SetTuning(ctx context.Context, in *pb.SetTuningRequest, opts ...grpc.CallOption) (*pb.TuningState, error) {
	if f.tuningErr != nil {
		return nil, f.tuningErr
	}
	f.setRequests = append(f.setRequests, proto.Clone(in).(*pb.SetTuningRequest))
	return f.tuning, nil
}

func (f *fakeAI) UploadModel(ctx context.Context, opts ...grpc.CallOption) (grpc.ClientStreamingClient[pb.UploadModelRequest, pb.UploadModelResponse], error) {
	return f.upload, nil
}

func (f *fakeAI) StreamLogs(ctx context.Context, in *pb.StreamLogsRequest, opts ...grpc.CallOption) (grpc.ServerStreamingClient[pb.LogEntry], error) {
	f.logRequest = proto.Clone(in).(*pb.StreamLogsRequest)
	return &fakeLogStream{entries: f.logEntries}, nil
}

func testServer(t *testing.T, ai *fakeAI, env string) (*httptest.Server, *predlog.Store) {
	t.Helper()
	store, err := predlog.Open(filepath.Join(t.TempDir(), "predictions.db"))
	if err != nil {
		t.Fatalf("opening store: %v", err)
	}
	t.Cleanup(func() { store.Close() })
	mux := http.NewServeMux()
	New(ai, store, config.Config{Env: env}).Register(mux)
	srv := httptest.NewServer(mux)
	t.Cleanup(srv.Close)
	return srv, store
}

func decodeJSON(t *testing.T, resp *http.Response, into any) {
	t.Helper()
	defer resp.Body.Close()
	if err := json.NewDecoder(resp.Body).Decode(into); err != nil {
		t.Fatalf("decoding response: %v", err)
	}
}

// ---- tests ----

func TestStatusReportsEnvTuningAndTotal(t *testing.T) {
	ai := &fakeAI{tuning: &pb.TuningState{
		ConfidenceThreshold: 0.6, ModelLoaded: true, NumClasses: 150, DebugMode: true,
	}}
	srv, store := testServer(t, ai, config.EnvDev)
	if err := store.Insert(predlog.Record{Word: "x"}); err != nil {
		t.Fatal(err)
	}

	resp, err := http.Get(srv.URL + "/api/v1/admin/status")
	if err != nil {
		t.Fatal(err)
	}
	var body struct {
		Env              string      `json:"env"`
		Debug            bool        `json:"debug"`
		AIOnline         bool        `json:"ai_online"`
		Tuning           *tuningJSON `json:"tuning"`
		PredictionsTotal int64       `json:"predictions_total"`
	}
	decodeJSON(t, resp, &body)
	if body.Env != config.EnvDev || !body.Debug || !body.AIOnline {
		t.Fatalf("unexpected status: %+v", body)
	}
	if body.Tuning == nil || body.Tuning.NumClasses != 150 || !body.Tuning.DebugMode {
		t.Fatalf("tuning not surfaced: %+v", body.Tuning)
	}
	if body.PredictionsTotal != 1 {
		t.Fatalf("expected 1 logged prediction, got %d", body.PredictionsTotal)
	}
}

func TestStatusSurvivesAIDown(t *testing.T) {
	ai := &fakeAI{tuningErr: status.Error(codes.Unavailable, "down")}
	srv, _ := testServer(t, ai, config.EnvProd)
	resp, err := http.Get(srv.URL + "/api/v1/admin/status")
	if err != nil {
		t.Fatal(err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status must degrade gracefully, got %d", resp.StatusCode)
	}
	var body struct {
		AIOnline bool   `json:"ai_online"`
		AIError  string `json:"ai_error"`
	}
	decodeJSON(t, resp, &body)
	if body.AIOnline || body.AIError == "" {
		t.Fatalf("expected ai_online=false with error, got %+v", body)
	}
}

func TestPredictionsFilterAndPaginate(t *testing.T) {
	srv, store := testServer(t, &fakeAI{}, config.EnvDev)
	for i, w := range []string{"a", "b", "a"} {
		err := store.Insert(predlog.Record{Seq: uint64(i), Word: w,
			Top: []predlog.ClassProb{{Label: w, Prob: 0.9}}})
		if err != nil {
			t.Fatal(err)
		}
	}
	resp, err := http.Get(srv.URL + "/api/v1/admin/predictions?word=a&limit=1")
	if err != nil {
		t.Fatal(err)
	}
	var body struct {
		Total   int64            `json:"total"`
		Records []predlog.Record `json:"records"`
	}
	decodeJSON(t, resp, &body)
	if body.Total != 3 {
		t.Fatalf("expected total 3, got %d", body.Total)
	}
	if len(body.Records) != 1 || body.Records[0].Word != "a" || body.Records[0].Seq != 2 {
		t.Fatalf("expected newest 'a' record, got %+v", body.Records)
	}
	if len(body.Records[0].Top) != 1 || body.Records[0].Top[0].Prob != 0.9 {
		t.Fatalf("top breakdown lost: %+v", body.Records[0].Top)
	}

	bad, err := http.Get(srv.URL + "/api/v1/admin/predictions?limit=nope")
	if err != nil {
		t.Fatal(err)
	}
	bad.Body.Close()
	if bad.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 for bad limit, got %d", bad.StatusCode)
	}
}

func TestClearPredictions(t *testing.T) {
	srv, store := testServer(t, &fakeAI{}, config.EnvDev)
	for i := 0; i < 3; i++ {
		if err := store.Insert(predlog.Record{Seq: uint64(i), Word: "x"}); err != nil {
			t.Fatal(err)
		}
	}
	req, err := http.NewRequest(http.MethodDelete, srv.URL+"/api/v1/admin/predictions", nil)
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusNoContent {
		t.Fatalf("expected 204 No Content, got %d", resp.StatusCode)
	}
	n, err := store.Count()
	if err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Fatalf("expected 0 records after DELETE, got %d", n)
	}
}

func multipartBody(t *testing.T, files map[string][]byte) (*bytes.Buffer, string) {
	t.Helper()
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	for field, payload := range files {
		fw, err := mw.CreateFormFile(field, field+".bin")
		if err != nil {
			t.Fatal(err)
		}
		if _, err := fw.Write(payload); err != nil {
			t.Fatal(err)
		}
	}
	mw.Close()
	return &buf, mw.FormDataContentType()
}

func TestUploadModelStreamsFilesToAI(t *testing.T) {
	upload := &fakeUploadStream{response: &pb.UploadModelResponse{
		Reloaded: true, NumClasses: 150, SequenceLen: 30, FeatureDim: 441,
	}}
	srv, _ := testServer(t, &fakeAI{upload: upload}, config.EnvDev)

	model := bytes.Repeat([]byte("m"), 3_000_000) // forces multiple chunks
	labelMap := []byte(`{"a":0}`)
	body, contentType := multipartBody(t, map[string][]byte{
		"model": model, "label_map": labelMap,
	})
	resp, err := http.Post(srv.URL+"/api/v1/admin/model", contentType, body)
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Reloaded   bool   `json:"reloaded"`
		NumClasses uint32 `json:"num_classes"`
	}
	decodeJSON(t, resp, &result)
	if resp.StatusCode != http.StatusOK || !result.Reloaded || result.NumClasses != 150 {
		t.Fatalf("unexpected upload result: code=%d %+v", resp.StatusCode, result)
	}

	// Reassemble what reached the AI service and verify headers + bytes.
	received := map[pb.FileKind][]byte{}
	declared := map[pb.FileKind]uint64{}
	var current pb.FileKind
	for _, req := range upload.requests {
		if h := req.GetHeader(); h != nil {
			current = h.GetKind()
			declared[current] = h.GetSizeBytes()
			continue
		}
		received[current] = append(received[current], req.GetChunk()...)
	}
	if !bytes.Equal(received[pb.FileKind_FILE_KIND_TFLITE_MODEL], model) {
		t.Fatalf("model bytes corrupted in transit (%d received)",
			len(received[pb.FileKind_FILE_KIND_TFLITE_MODEL]))
	}
	if !bytes.Equal(received[pb.FileKind_FILE_KIND_LABEL_MAP], labelMap) {
		t.Fatal("label map bytes corrupted in transit")
	}
	if declared[pb.FileKind_FILE_KIND_TFLITE_MODEL] != uint64(len(model)) {
		t.Fatalf("declared model size %d != %d",
			declared[pb.FileKind_FILE_KIND_TFLITE_MODEL], len(model))
	}
}

func TestUploadModelRequiresLabelMap(t *testing.T) {
	srv, _ := testServer(t, &fakeAI{upload: &fakeUploadStream{}}, config.EnvDev)
	body, contentType := multipartBody(t, map[string][]byte{"model": []byte("m")})
	resp, err := http.Post(srv.URL+"/api/v1/admin/model", contentType, body)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

func TestUploadModelMapsAIRejection(t *testing.T) {
	upload := &fakeUploadStream{err: status.Error(codes.InvalidArgument, "bad flatbuffer")}
	srv, _ := testServer(t, &fakeAI{upload: upload}, config.EnvDev)
	body, contentType := multipartBody(t, map[string][]byte{
		"model": []byte("m"), "label_map": []byte("{}"),
	})
	resp, err := http.Post(srv.URL+"/api/v1/admin/model", contentType, body)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400 from AI rejection, got %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "application/problem+json" {
		t.Fatalf("expected problem+json, got %s", ct)
	}
}

func TestSetTuningForwardsFieldsButNeverDebug(t *testing.T) {
	ai := &fakeAI{tuning: &pb.TuningState{ConfidenceThreshold: 0.7}}
	srv, _ := testServer(t, ai, config.EnvDev)
	req, err := http.NewRequest(http.MethodPut, srv.URL+"/api/v1/admin/tuning",
		strings.NewReader(`{"confidence_threshold": 0.7}`))
	if err != nil {
		t.Fatal(err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var state tuningJSON
	decodeJSON(t, resp, &state)
	if state.ConfidenceThreshold != 0.7 {
		t.Fatalf("unexpected tuning response: %+v", state)
	}
	if len(ai.setRequests) != 1 {
		t.Fatalf("expected 1 SetTuning call, got %d", len(ai.setRequests))
	}
	sent := ai.setRequests[0]
	if sent.GetConfidenceThreshold() != 0.7 || sent.IdleMinFramesWithHands != nil {
		t.Fatalf("unexpected SetTuning request: %v", sent)
	}
	if sent.DebugMode != nil {
		t.Fatal("tuning endpoint must never set debug_mode (ENV owns it)")
	}
}

func TestLogsStreamAsSSE(t *testing.T) {
	ai := &fakeAI{logEntries: []*pb.LogEntry{
		{TimestampMs: 1000, Level: pb.LogLevel_LOG_LEVEL_INFO, Logger: "inference.server", Message: "hello"},
		{TimestampMs: 2000, Level: pb.LogLevel_LOG_LEVEL_DEBUG, Logger: "inference.engine", Message: "detail"},
	}}
	srv, _ := testServer(t, ai, config.EnvDev)
	resp, err := http.Get(srv.URL + "/api/v1/admin/logs?history=10")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if ct := resp.Header.Get("Content-Type"); ct != "text/event-stream" {
		t.Fatalf("expected SSE content type, got %q", ct)
	}
	data, err := io.ReadAll(resp.Body) // fake stream EOFs after two entries
	if err != nil {
		t.Fatal(err)
	}
	events := strings.Split(strings.TrimSpace(string(data)), "\n\n")
	if len(events) != 2 {
		t.Fatalf("expected 2 SSE events, got %d: %q", len(events), data)
	}
	var entry struct {
		Level   string `json:"level"`
		Message string `json:"message"`
	}
	payload := strings.TrimPrefix(events[1], "data: ")
	if err := json.Unmarshal([]byte(payload), &entry); err != nil {
		t.Fatalf("decoding SSE payload %q: %v", payload, err)
	}
	if entry.Level != "DEBUG" || entry.Message != "detail" {
		t.Fatalf("unexpected entry: %+v", entry)
	}
	// Dev default forwards DEBUG level to the AI service.
	if ai.logRequest.GetMinLevel() != pb.LogLevel_LOG_LEVEL_DEBUG {
		t.Fatalf("Dev default min_level must be DEBUG, got %v", ai.logRequest.GetMinLevel())
	}
}
