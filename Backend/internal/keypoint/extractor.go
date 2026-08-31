// Package keypoint turns a recorded sign clip into avatar keypoint frames by
// calling the Python inference service's ExtractKeypoints RPC (MediaPipe
// pose+hand landmarks). Extraction is an offline, one-shot job — deliberately
// off the realtime landmark path — but it lives in the AI service because
// that is where the Python runtime and MediaPipe are installed; the gateway
// image ships a single static Go binary and no interpreter.
package keypoint

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"google.golang.org/grpc"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

// chunkLen is the clip chunk size per the proto contract's suggestion
// (<= 1 MiB per message), matching the model-upload proxy in internal/admin.
const chunkLen = 1 << 20

// defaultExtension mirrors the service-side default: the admin webui's
// MediaRecorder produces WebM.
const defaultExtension = ".webm"

// ErrNotConfigured is returned when the extractor holds no AI client, so
// callers can reject recording uploads with a clear message.
var ErrNotConfigured = errors.New(
	"keypoint: extractor has no AI service client")

// Client is the slice of the generated TslInference client this package uses.
// *pb.TslInferenceClient satisfies it; tests inject a fake, so they need
// neither a gRPC server nor a Python runtime.
type Client interface {
	ExtractKeypoints(ctx context.Context, opts ...grpc.CallOption) (
		grpc.ClientStreamingClient[pb.ExtractKeypointsRequest, pb.ExtractKeypointsResponse], error)
}

// Extractor calls ExtractKeypoints on the AI service to turn a clip into
// avatar keypoint frames (JSON: [[{x,y,z},...],...]).
type Extractor struct {
	client Client
	frames int
}

// New builds an Extractor over the AI service client. frames is how many
// animation frames to request (<=0 lets the service pick its own default).
func New(client Client, frames int) *Extractor {
	return &Extractor{client: client, frames: frames}
}

// Configured reports whether an AI service client is available.
func (e *Extractor) Configured() bool {
	return e != nil && e.client != nil
}

// ExtractReader streams r to the AI service as the clip named by ext (e.g.
// ".webm") and returns the validated keypoint-frame JSON. The whole call is
// bounded by ctx — the service stages the clip and removes it itself.
func (e *Extractor) ExtractReader(ctx context.Context, r io.Reader, ext string) (json.RawMessage, error) {
	if !e.Configured() {
		return nil, ErrNotConfigured
	}
	if ext == "" {
		ext = defaultExtension
	}

	stream, err := e.client.ExtractKeypoints(ctx)
	if err != nil {
		return nil, fmt.Errorf("keypoint extraction failed: opening stream: %w", err)
	}

	info := &pb.ExtractInfo{Extension: strings.ToLower(ext)}
	if e.frames > 0 {
		info.Frames = uint32(e.frames)
	}
	err = stream.Send(&pb.ExtractKeypointsRequest{
		Payload: &pb.ExtractKeypointsRequest_Info{Info: info},
	})
	if err != nil {
		return nil, finish(stream, err)
	}

	for {
		buf := make([]byte, chunkLen) // fresh buffer: Send retains it
		n, readErr := r.Read(buf)
		if n > 0 {
			sendErr := stream.Send(&pb.ExtractKeypointsRequest{
				Payload: &pb.ExtractKeypointsRequest_Chunk{Chunk: buf[:n]},
			})
			if sendErr != nil {
				return nil, finish(stream, sendErr)
			}
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return nil, fmt.Errorf("keypoint: reading upload: %w", readErr)
		}
	}

	resp, err := stream.CloseAndRecv()
	if err != nil {
		return nil, fmt.Errorf("keypoint extraction failed: %w", err)
	}
	return validateFrames([]byte(resp.GetFramesJson()))
}

// finish turns a Send failure into the definitive error: a stream that the
// service aborted fails Send with a generic EOF, and the real gRPC status
// only arrives from CloseAndRecv.
func finish(
	stream grpc.ClientStreamingClient[pb.ExtractKeypointsRequest, pb.ExtractKeypointsResponse],
	sendErr error,
) error {
	if _, recvErr := stream.CloseAndRecv(); recvErr != nil {
		sendErr = recvErr
	}
	return fmt.Errorf("keypoint extraction failed: %w", sendErr)
}

// validateFrames ensures the service emitted a non-empty JSON array of {x,y,z}
// frames, then returns the raw bytes for storage.
func validateFrames(out []byte) (json.RawMessage, error) {
	var frames [][]struct {
		X float64 `json:"x"`
		Y float64 `json:"y"`
		Z float64 `json:"z"`
	}
	if err := json.Unmarshal(out, &frames); err != nil {
		return nil, fmt.Errorf("keypoint: unparseable service output: %w", err)
	}
	if len(frames) == 0 {
		return nil, errors.New("keypoint: extractor returned no frames")
	}
	return json.RawMessage(out), nil
}
