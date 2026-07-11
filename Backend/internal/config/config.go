// Package config loads server configuration from environment variables.
package config

import "os"

type Config struct {
	// HTTPAddr is the listen address for the REST/WebSocket API.
	HTTPAddr string
	// AIAddr is the Python gRPC inference service address.
	AIAddr string
}

func Load() Config {
	return Config{
		HTTPAddr: envOr("SIGNMIND_HTTP_ADDR", ":8080"),
		AIAddr:   envOr("SIGNMIND_AI_ADDR", "localhost:50051"),
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
