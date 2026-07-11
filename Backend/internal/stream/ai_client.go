package stream

import (
	"context"
	"fmt"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

// AIStream is one bidirectional inference stream (a live gRPC
// TslInference.StreamInference call, or a fake in tests).
type AIStream interface {
	Send(*pb.LandmarkFrame) error
	Recv() (*pb.Prediction, error)
	CloseSend() error
}

// AIClient opens inference streams against the Python AI service.
type AIClient interface {
	OpenStream(ctx context.Context) (AIStream, error)
}

// GRPCClient is the production AIClient over gRPC bidirectional streaming
// (no HTTP fallback on the landmark path — root DOX rule).
type GRPCClient struct {
	client pb.TslInferenceClient
}

func NewGRPCClient(addr string) (*GRPCClient, error) {
	conn, err := grpc.NewClient(addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		return nil, fmt.Errorf("connecting to AI service at %s: %w", addr, err)
	}
	return &GRPCClient{client: pb.NewTslInferenceClient(conn)}, nil
}

func (c *GRPCClient) OpenStream(ctx context.Context) (AIStream, error) {
	return c.client.StreamInference(ctx)
}

// Raw exposes the generated client for the management RPCs (UploadModel,
// StreamLogs, tuning) used by the admin API.
func (c *GRPCClient) Raw() pb.TslInferenceClient {
	return c.client
}
