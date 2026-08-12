package stream

import (
	"context"
	"testing"
)

func TestSharedSecretCredsAttachesMetadata(t *testing.T) {
	creds := sharedSecretCreds{secret: "s3cr3t"}
	md, err := creds.GetRequestMetadata(context.Background())
	if err != nil {
		t.Fatalf("GetRequestMetadata: %v", err)
	}
	if md["x-signmind-shared-secret"] != "s3cr3t" {
		t.Fatalf("expected shared secret in metadata, got %v", md)
	}
}

func TestSharedSecretCredsDoesNotRequireTransportSecurity(t *testing.T) {
	creds := sharedSecretCreds{secret: "s3cr3t"}
	if creds.RequireTransportSecurity() {
		t.Fatalf("expected RequireTransportSecurity() == false (channel is plaintext gRPC)")
	}
}

func TestNewGRPCClientWithoutSecretSucceeds(t *testing.T) {
	// grpc.NewClient is lazy (no dial until first RPC), so this only proves
	// construction with an empty secret (local-dev / AI-service-unauthenticated
	// case) still wires up cleanly.
	client, err := NewGRPCClient("localhost:0", "")
	if err != nil {
		t.Fatalf("NewGRPCClient: %v", err)
	}
	if client == nil {
		t.Fatal("expected non-nil client")
	}
}

func TestNewGRPCClientWithSecretSucceeds(t *testing.T) {
	client, err := NewGRPCClient("localhost:0", "s3cr3t")
	if err != nil {
		t.Fatalf("NewGRPCClient: %v", err)
	}
	if client == nil {
		t.Fatal("expected non-nil client")
	}
}
