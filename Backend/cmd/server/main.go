package main

import (
	"log"
	"net/http"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/config"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/stream"
)

func main() {
	cfg := config.Load()

	aiClient, err := stream.NewGRPCClient(cfg.AIAddr)
	if err != nil {
		log.Fatalf("creating AI client: %v", err)
	}

	mux := http.NewServeMux()
	mux.Handle("/api/v1/stream", stream.NewHandler(aiClient))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	log.Printf("SignMind AI backend listening on %s (AI service: %s)", cfg.HTTPAddr, cfg.AIAddr)
	if err := http.ListenAndServe(cfg.HTTPAddr, mux); err != nil {
		log.Fatalf("http server: %v", err)
	}
}
