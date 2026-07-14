package main

import (
	"context"
	"database/sql"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/admin"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/auth"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/config"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/conversation"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/keypoint"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/learn"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/predlog"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/stream"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/webui"

	_ "modernc.org/sqlite"
)

const (
	debugSyncInterval  = 30 * time.Second
	tokenPurgeInterval = 1 * time.Hour
)

func main() {
	cfg := config.Load()
	if cfg.IsDev() {
		// Dev enables all debug: precise timestamps, file:line, request log.
		log.SetFlags(log.LstdFlags | log.Lmicroseconds | log.Lshortfile)
	}

	// ---- shared SQLite database ----
	db, err := openDB(cfg.DBPath)
	if err != nil {
		log.Fatalf("opening database: %v", err)
	}
	defer db.Close()

	store, err := predlog.OpenWith(db)
	if err != nil {
		log.Fatalf("opening prediction log: %v", err)
	}

	// ---- auth ----
	authStore, err := auth.OpenStore(db)
	if err != nil {
		log.Fatalf("opening auth store: %v", err)
	}

	jwtSecret := resolveJWTSecret(cfg)
	seedAdmin(authStore, cfg)

	loginRL := auth.NewRateLimiter(5, time.Minute)
	signupRL := auth.NewRateLimiter(10, 24*time.Hour)
	authHandler := auth.NewHandler(authStore, jwtSecret, cfg.AllowSignup, cfg.TrustProxy, loginRL, signupRL)

	// Middleware: any authenticated user / admin role.
	requireAuth := auth.RequireAuth(jwtSecret)
	adminMW := func(next http.Handler) http.Handler {
		return requireAuth(auth.RequireRole(auth.RoleAdmin)(next))
	}

	// ---- AI client ----
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

	// ---- routes ----
	// The data endpoints require a valid JWT (any role): the Flutter client
	// sends "Authorization: Bearer" — on the WS handshake for /stream.
	mux := http.NewServeMux()
	mux.Handle("/api/v1/stream", requireAuth(stream.NewHandler(aiClient, record)))
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	// Auth routes (login, signup, refresh, logout, me, admin user CRUD).
	authHandler.Register(mux, adminMW)

	// Admin routes — protected by JWT + admin role.
	adminHandler := admin.New(aiClient.Raw(), store, cfg)
	adminHandler.RegisterProtected(mux, adminMW)

	// Learning tab: dictionary, exercise roadmap, progress (user routes)
	// plus topic/exercise CRUD (admin routes).
	learnStore, err := learn.OpenWith(db)
	if err != nil {
		log.Fatalf("opening learn store: %v", err)
	}
	if err := learn.Seed(learnStore); err != nil {
		log.Fatalf("seeding learn content: %v", err)
	}
	// Conversation avatar signs the reply by stitching each gloss word's
	// recorded keypoints from the shared dictionary library. The lookup keeps
	// conversation decoupled from learn (it depends on a func, not the store).
	signLookup := func(word string) (json.RawMessage, bool) {
		sg, err := learnStore.GetSign(word)
		if err != nil || len(sg.KeypointFrames) == 0 {
			return nil, false
		}
		return sg.KeypointFrames, true
	}
	mux.Handle("/api/v1/conversation", requireAuth(http.HandlerFunc(conversation.Handler(signLookup))))
	// Sign-recording keypoint extractor (admin webui). Unconfigured when the
	// SIGNMIND_KEYPOINT_PY / SIGNMIND_EXTRACT_SCRIPT paths are unset — recording
	// uploads then return 503, the rest of the learn API is unaffected.
	extractor := keypoint.New(cfg.KeypointPython, cfg.ExtractScript, 0)
	learn.NewHandler(learnStore, extractor).RegisterProtected(mux, requireAuth, adminMW)

	// Static webui served at / (API routes win by mux specificity).
	mux.Handle("/", webui.Handler())

	// ---- background goroutines ----
	ctx := context.Background()

	// ENV owns the AI service's debug_mode; the sync loop reasserts it
	// across AI restarts (runtime tuning resets there).
	go admin.SyncDebugMode(ctx, aiClient.Raw(), cfg.IsDev(), debugSyncInterval)

	// Purge expired refresh tokens periodically.
	go auth.PurgeLoop(ctx, authStore, tokenPurgeInterval)

	var handler http.Handler = mux
	if cfg.IsDev() {
		handler = requestLog(mux)
	}

	log.Printf("SignMind AI backend listening on %s (AI service: %s, ENV: %s, signup: %v)",
		cfg.HTTPAddr, cfg.AIAddr, cfg.Env, cfg.AllowSignup)
	if err := http.ListenAndServe(cfg.HTTPAddr, handler); err != nil {
		log.Fatalf("http server: %v", err)
	}
}

// openDB creates parent directories and opens the shared SQLite database
// with WAL + busy_timeout.
func openDB(path string) (*sql.DB, error) {
	if dir := filepath.Dir(path); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("creating database dir: %w", err)
		}
	}
	dsn := "file:" + filepath.ToSlash(path) +
		"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"
	return sql.Open("sqlite", dsn)
}

// resolveJWTSecret loads or generates the HMAC-SHA256 signing key.
func resolveJWTSecret(cfg config.Config) []byte {
	if cfg.JWTSecret != "" {
		return []byte(cfg.JWTSecret)
	}
	if !cfg.IsDev() {
		log.Fatal("SIGNMIND_JWT_SECRET is required in Prod — set it in .env or the environment")
	}
	secret, err := auth.GenerateRandomSecret()
	if err != nil {
		log.Fatalf("generating dev JWT secret: %v", err)
	}
	log.Printf("auth: dev mode — auto-generated JWT secret: %s", hex.EncodeToString(secret))
	return secret
}

// seedAdmin creates the initial admin account from config if no admin exists.
func seedAdmin(store *auth.Store, cfg config.Config) {
	if cfg.AdminEmail == "" || cfg.AdminPassword == "" {
		return
	}
	// Check if any admin already exists.
	users, err := store.ListUsers()
	if err != nil {
		log.Fatalf("checking existing admins: %v", err)
	}
	for _, u := range users {
		if u.Role == auth.RoleAdmin {
			log.Printf("auth: admin already exists (id=%d, email=%s) — skipping seed", u.ID, u.Email)
			return
		}
	}
	u, err := store.CreateUser(cfg.AdminEmail, cfg.AdminPassword, auth.RoleAdmin)
	if err != nil {
		log.Fatalf("seeding admin user: %v", err)
	}
	log.Printf("auth: seeded admin user id=%d email=%s", u.ID, u.Email)
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

