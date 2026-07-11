package auth

import (
	"context"
	"log"
	"net/http"
	"strings"
	"sync"
	"time"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/httpapi"
)

// claimsKey is the context key for authenticated JWT claims.
type claimsKey struct{}

// ClaimsFromContext extracts the authenticated Claims from a request context.
// Returns zero Claims and false if the request is not authenticated.
func ClaimsFromContext(ctx context.Context) (Claims, bool) {
	c, ok := ctx.Value(claimsKey{}).(Claims)
	return c, ok
}

// RequireAuth returns middleware that validates the JWT access token from
// either the Authorization header ("Bearer <token>") or the
// "signmind_access" cookie. On success the Claims are injected into the
// request context; on failure a 401 RFC 7807 problem is returned.
func RequireAuth(secret []byte) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token := extractToken(r)
			if token == "" {
				httpapi.WriteProblem(w, httpapi.NewProblem(
					http.StatusUnauthorized, "Authentication required",
					"provide a Bearer token or signmind_access cookie"))
				return
			}
			claims, err := ValidateAccessToken(token, secret)
			if err != nil {
				httpapi.WriteProblem(w, httpapi.NewProblem(
					http.StatusUnauthorized, "Invalid token", err.Error()))
				return
			}
			ctx := context.WithValue(r.Context(), claimsKey{}, claims)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// RequireRole returns middleware that checks whether the authenticated
// user has one of the specified roles. Must be stacked after RequireAuth.
func RequireRole(roles ...string) func(http.Handler) http.Handler {
	allowed := make(map[string]bool, len(roles))
	for _, r := range roles {
		allowed[r] = true
	}
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			claims, ok := ClaimsFromContext(r.Context())
			if !ok {
				httpapi.WriteProblem(w, httpapi.NewProblem(
					http.StatusUnauthorized, "Authentication required", ""))
				return
			}
			if !allowed[claims.Role] {
				httpapi.WriteProblem(w, httpapi.NewProblem(
					http.StatusForbidden, "Insufficient permissions",
					"your role does not grant access to this resource"))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// extractToken reads the JWT from the Authorization header (preferred) or
// the signmind_access cookie (webui fallback).
func extractToken(r *http.Request) string {
	if auth := r.Header.Get("Authorization"); auth != "" {
		if strings.HasPrefix(auth, "Bearer ") {
			return strings.TrimPrefix(auth, "Bearer ")
		}
	}
	if c, err := r.Cookie("signmind_access"); err == nil {
		return c.Value
	}
	return ""
}

// ---- rate limiting ----

// RateLimiter tracks per-key request counts within a sliding window.
type RateLimiter struct {
	mu      sync.Mutex
	entries map[string][]time.Time
	max     int
	window  time.Duration
}

// NewRateLimiter creates a rate limiter allowing max requests per window
// per key.
func NewRateLimiter(max int, window time.Duration) *RateLimiter {
	return &RateLimiter{
		entries: make(map[string][]time.Time),
		max:     max,
		window:  window,
	}
}

// Allow checks if a request from key is within the rate limit.
func (rl *RateLimiter) Allow(key string) bool {
	rl.mu.Lock()
	defer rl.mu.Unlock()

	now := time.Now()
	cutoff := now.Add(-rl.window)

	// Prune expired entries.
	times := rl.entries[key]
	valid := times[:0]
	for _, t := range times {
		if t.After(cutoff) {
			valid = append(valid, t)
		}
	}

	if len(valid) >= rl.max {
		rl.entries[key] = valid
		return false
	}

	rl.entries[key] = append(valid, now)
	return true
}

// RateLimitMiddleware wraps a handler with per-IP rate limiting. Returns
// 429 when the limit is exceeded.
func RateLimitMiddleware(rl *RateLimiter) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ip := clientIP(r)
			if !rl.Allow(ip) {
				httpapi.WriteProblem(w, httpapi.NewProblem(
					http.StatusTooManyRequests, "Rate limit exceeded",
					"too many requests — try again later"))
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}

// clientIP extracts the client IP, preferring X-Forwarded-For (first entry)
// when behind a reverse proxy, falling back to RemoteAddr.
func clientIP(r *http.Request) string {
	if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
		parts := strings.SplitN(xff, ",", 2)
		return strings.TrimSpace(parts[0])
	}
	// RemoteAddr is "ip:port"; strip the port.
	addr := r.RemoteAddr
	if idx := strings.LastIndex(addr, ":"); idx != -1 {
		return addr[:idx]
	}
	return addr
}

// ---- startup logging ----

// PurgeLoop runs periodic cleanup of expired refresh tokens.
func PurgeLoop(ctx context.Context, store *Store, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			n, err := store.PurgeExpiredTokens()
			if err != nil {
				log.Printf("auth: purging expired tokens: %v", err)
			} else if n > 0 {
				log.Printf("auth: purged %d expired refresh tokens", n)
			}
		}
	}
}
