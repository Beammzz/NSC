package main

import (
	"context"
	"log"
	"net/http"
	"time"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/admin"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/config"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/conversation"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/predlog"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/stream"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/webui"
)

const debugSyncInterval = 30 * time.Second

func main() {
	cfg := config.Load()
	if cfg.IsDev() {
		// Dev enables all debug: precise timestamps, file:line, request log.
		log.SetFlags(log.LstdFlags | log.Lmicroseconds | log.Lshortfile)
	}

	store, err := predlog.Open(cfg.DBPath)
	if err != nil {
		log.Fatalf("opening prediction log: %v", err)
	}
	defer store.Close()

	aiClient, err := stream.NewGRPCClient(cfg.AIAddr)
	if err != nil {
		log.Fatalf("creating AI client: %v", err)
	}

	// Every prediction flowing to a client is also logged for the webui;
	// in Dev the AI service sends the full breakdown (debug_mode below).
	record := func(p *pb.Prediction) {
		if err := store.Insert(predlog.FromProto(p)); err != nil {
			log.Printf("prediction log: %v", err)
		}
		if cfg.IsDev() {
			log.Printf(
				"prediction seq=%d word=%q conf=%.3f idle=%v uncertain=%v top=%d other=%.3f",
				p.GetSeq(), p.GetWord(), p.GetConfidence(), p.GetIsIdle(),
				p.GetIsUncertain(), len(p.GetTop()), p.GetOtherProb())
		}
	}

	mux := http.NewServeMux()
	mux.Handle("/api/v1/stream", stream.NewHandler(aiClient, record))
	mux.HandleFunc("/api/v1/conversation", conversation.Handler())
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	admin.New(aiClient.Raw(), store, cfg).Register(mux)
	mux.Handle("/", webui.Handler())

	// ENV owns the AI service's debug_mode; the sync loop reasserts it
	// across AI restarts (runtime tuning resets there).
	go admin.SyncDebugMode(context.Background(), aiClient.Raw(), cfg.IsDev(), debugSyncInterval)

	var handler http.Handler = mux
	if cfg.IsDev() {
		handler = requestLog(mux)
	}

	log.Printf("SignMind AI backend listening on %s (AI service: %s, ENV: %s)",
		cfg.HTTPAddr, cfg.AIAddr, cfg.Env)
	if err := http.ListenAndServe(cfg.HTTPAddr, handler); err != nil {
		log.Fatalf("http server: %v", err)
	}
}

// requestLog is the Dev-only request logger. The original ResponseWriter is
// passed through untouched so WS upgrades (http.Hijacker) keep working;
// long-lived streams simply log when the connection ends.
func requestLog(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		next.ServeHTTP(w, r)
		log.Printf("%s %s (%s)", r.Method, r.URL.Path,
			time.Since(started).Round(time.Microsecond))
	})
}
