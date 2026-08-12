package stream

import (
	"context"
	"fmt"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

// sharedSecretCreds attaches the shared-secret metadata every RPC needs to
// pass the Python service's SharedSecretInterceptor (auth_interceptor.py).
// RequireTransportSecurity is false because the channel itself is plaintext
// gRPC (insecure.NewCredentials) on the internal network — this credential
// authenticates the caller, it does not encrypt the transport.
type sharedSecretCreds struct{ secret string }

func (c sharedSecretCreds) GetRequestMetadata(ctx context.Context, uri ...string) (map[string]string, error) {
	return map[string]string{"x-signmind-shared-secret": c.secret}, nil
}

func (c sharedSecretCreds) RequireTransportSecurity() bool { return false }

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

// NewGRPCClient dials the Python AI service. sharedSecret, when non-empty,
// is sent as metadata on every RPC (unary and streaming) so the AI
// service's SharedSecretInterceptor admits this client; empty matches an
// AI service run without SIGNMIND_AI_SHARED_SECRET set (local dev).
func NewGRPCClient(addr, sharedSecret string) (*GRPCClient, error) {
	opts := []grpc.DialOption{grpc.WithTransportCredentials(insecure.NewCredentials())}
	if sharedSecret != "" {
		opts = append(opts, grpc.WithPerRPCCredentials(sharedSecretCreds{secret: sharedSecret}))
	}
	conn, err := grpc.NewClient(addr, opts...)
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
