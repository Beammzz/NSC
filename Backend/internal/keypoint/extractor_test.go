package keypoint

import (
	"context"
	"errors"
	"io"
	"strings"
	"testing"

	"google.golang.org/grpc"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

// fakeStream records what the extractor streamed and returns a canned
// response, so these tests need neither a gRPC server nor a Python runtime.
type fakeStream struct {
	grpc.ClientStream // never called; embedded to satisfy the interface

	resp *pb.ExtractKeypointsResponse
	err  error

	sendErr error
	info    *pb.ExtractInfo
	body    []byte
	chunks  int
	closed  bool
}

func (f *fakeStream) Send(req *pb.ExtractKeypointsRequest) error {
	if f.sendErr != nil {
		return f.sendErr
	}
	switch payload := req.GetPayload().(type) {
	case *pb.ExtractKeypointsRequest_Info:
		f.info = payload.Info
	case *pb.ExtractKeypointsRequest_Chunk:
		f.body = append(f.body, payload.Chunk...)
		f.chunks++
	}
	return nil
}

func (f *fakeStream) CloseAndRecv() (*pb.ExtractKeypointsResponse, error) {
	f.closed = true
	return f.resp, f.err
}

// fakeClient hands out one fakeStream and records the open attempt.
type fakeClient struct {
	stream  *fakeStream
	openErr error
	opened  int
}

func (c *fakeClient) ExtractKeypoints(ctx context.Context, opts ...grpc.CallOption) (
	grpc.ClientStreamingClient[pb.ExtractKeypointsRequest, pb.ExtractKeypointsResponse], error) {
	c.opened++
	if c.openErr != nil {
		return nil, c.openErr
	}
	return c.stream, nil
}

func newFake(framesJSON string) (*fakeClient, *fakeStream) {
	st := &fakeStream{resp: &pb.ExtractKeypointsResponse{FramesJson: framesJSON}}
	return &fakeClient{stream: st}, st
}

func TestExtractReaderStreamsClipAndReturnsFrames(t *testing.T) {
	const payload = `[[{"x":0.1,"y":0.2,"z":0}]]`
	cl, st := newFake(payload)
	e := New(cl, 12)

	raw, err := e.ExtractReader(context.Background(), strings.NewReader("fake video bytes"), ".webm")
	if err != nil {
		t.Fatalf("ExtractReader: %v", err)
	}
	if string(raw) != payload {
		t.Errorf("raw = %s, want %s", raw, payload)
	}
	if string(st.body) != "fake video bytes" {
		t.Errorf("streamed body = %q, want the clip bytes", st.body)
	}
	if st.info.GetExtension() != ".webm" {
		t.Errorf("extension = %q, want .webm", st.info.GetExtension())
	}
	if st.info.GetFrames() != 12 {
		t.Errorf("frames = %d, want 12", st.info.GetFrames())
	}
	if !st.closed {
		t.Error("stream was never closed")
	}
}

func TestExtractReaderDefaultsExtensionAndLowercases(t *testing.T) {
	cl, st := newFake(`[[{"x":0,"y":0,"z":0}]]`)
	if _, err := New(cl, 0).ExtractReader(context.Background(), strings.NewReader("v"), ""); err != nil {
		t.Fatal(err)
	}
	if st.info.GetExtension() != ".webm" {
		t.Errorf("empty ext = %q, want the .webm default", st.info.GetExtension())
	}

	cl2, st2 := newFake(`[[{"x":0,"y":0,"z":0}]]`)
	if _, err := New(cl2, 0).ExtractReader(context.Background(), strings.NewReader("v"), ".MP4"); err != nil {
		t.Fatal(err)
	}
	if st2.info.GetExtension() != ".mp4" {
		t.Errorf("ext = %q, want lowercased .mp4", st2.info.GetExtension())
	}
}

func TestExtractReaderOmitsFrameCountWhenZero(t *testing.T) {
	cl, st := newFake(`[[{"x":0,"y":0,"z":0}]]`)
	if _, err := New(cl, 0).ExtractReader(context.Background(), strings.NewReader("v"), ".webm"); err != nil {
		t.Fatal(err)
	}
	if st.info.GetFrames() != 0 {
		t.Errorf("frames = %d, want 0 so the service picks its default", st.info.GetFrames())
	}
}

func TestExtractReaderChunksLargeClips(t *testing.T) {
	cl, st := newFake(`[[{"x":0,"y":0,"z":0}]]`)
	clip := strings.Repeat("a", chunkLen+1024)

	if _, err := New(cl, 0).ExtractReader(context.Background(), strings.NewReader(clip), ".webm"); err != nil {
		t.Fatal(err)
	}
	if st.chunks < 2 {
		t.Errorf("chunks = %d, want the clip split across several messages", st.chunks)
	}
	if len(st.body) != len(clip) {
		t.Errorf("streamed %d bytes, want %d", len(st.body), len(clip))
	}
}

func TestExtractReaderRejectsEmptyFrames(t *testing.T) {
	cl, _ := newFake(`[]`)
	if _, err := New(cl, 0).ExtractReader(context.Background(), strings.NewReader("v"), ".webm"); err == nil {
		t.Fatal("expected an error for an empty frame array")
	}
}

func TestExtractReaderRejectsBadJSON(t *testing.T) {
	cl, _ := newFake("not json")
	if _, err := New(cl, 0).ExtractReader(context.Background(), strings.NewReader("v"), ".webm"); err == nil {
		t.Fatal("expected an error for unparseable output")
	}
}

func TestExtractReaderWrapsServiceError(t *testing.T) {
	cl, st := newFake("")
	st.err = errors.New("cannot extract keypoints from the clip")

	_, err := New(cl, 0).ExtractReader(context.Background(), strings.NewReader("v"), ".webm")
	if err == nil {
		t.Fatal("expected the service error to propagate")
	}
	if !strings.Contains(err.Error(), "cannot extract keypoints") {
		t.Errorf("error %q lost the service detail", err)
	}
}

func TestExtractReaderReportsStatusFromCloseAndRecvOnSendFailure(t *testing.T) {
	// A stream the service aborted fails Send with a generic EOF; the real
	// status only arrives from CloseAndRecv, and that is what callers need.
	cl, st := newFake("")
	st.sendErr = io.EOF
	st.err = errors.New("clip exceeds the byte limit")

	_, err := New(cl, 0).ExtractReader(context.Background(), strings.NewReader("v"), ".webm")
	if err == nil {
		t.Fatal("expected an error when Send fails")
	}
	if !strings.Contains(err.Error(), "clip exceeds the byte limit") {
		t.Errorf("error %q reported the EOF instead of the service status", err)
	}
}

func TestExtractReaderWrapsOpenError(t *testing.T) {
	cl := &fakeClient{openErr: errors.New("connection refused")}
	if _, err := New(cl, 0).ExtractReader(context.Background(), strings.NewReader("v"), ".webm"); err == nil {
		t.Fatal("expected an error when the stream cannot be opened")
	}
}

func TestExtractReaderNotConfigured(t *testing.T) {
	e := New(nil, 0)
	_, err := e.ExtractReader(context.Background(), strings.NewReader("v"), ".webm")
	if !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("want ErrNotConfigured, got %v", err)
	}
}

func TestConfigured(t *testing.T) {
	if New(nil, 0).Configured() {
		t.Error("a nil client should not be configured")
	}
	cl, _ := newFake(`[[{"x":0,"y":0,"z":0}]]`)
	if !New(cl, 0).Configured() {
		t.Error("a client should be configured")
	}
	var nilExtractor *Extractor
	if nilExtractor.Configured() {
		t.Error("nil extractor should not be configured")
	}
}
