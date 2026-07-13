// Package config loads server configuration from environment variables,
// with a Backend/.env file as fallback (real env vars take precedence).
package config

import (
	"os"
	"strings"
)

const (
	EnvDev  = "Dev"
	EnvProd = "Prod"
)

type Config struct {
	// HTTPAddr is the listen address for the REST/WebSocket API.
	HTTPAddr string
	// AIAddr is the Python gRPC inference service address.
	AIAddr string
	// Env is EnvDev or EnvProd. Dev enables all debug: verbose gateway
	// logging and debug_mode on the Python inference service (full
	// probability breakdowns per prediction).
	Env string
	// DBPath is the SQLite file for the prediction log.
	DBPath string

	// JWTSecret is the HMAC-SHA256 signing key for access tokens.
	// Required in Prod; auto-generated if empty in Dev.
	JWTSecret string
	// AdminEmail is the initial admin account email, seeded on first boot
	// when no admin user exists.
	AdminEmail string
	// AdminPassword is the initial admin account password.
	AdminPassword string
	// AllowSignup enables the public POST /api/v1/auth/signup endpoint.
	// When false, only admins can create user accounts.
	AllowSignup bool
	// TrustProxy trusts X-Forwarded-* headers for client IP and scheme.
	// Enable ONLY when the server runs behind a reverse proxy that strips
	// client-supplied values; otherwise rate limits are spoofable.
	TrustProxy bool
}

func (c Config) IsDev() bool { return c.Env == EnvDev }

// Load reads .env from the working directory (if present), then the process
// environment on top of it.
func Load() Config {
	return load(parseDotEnv(".env"))
}

func load(fileVars map[string]string) Config {
	get := func(key, fallback string) string {
		if v := os.Getenv(key); v != "" {
			return v
		}
		if v := fileVars[key]; v != "" {
			return v
		}
		return fallback
	}
	env := EnvProd // unknown or missing values fail safe to Prod
	if strings.EqualFold(get("ENV", EnvProd), EnvDev) {
		env = EnvDev
	}
	return Config{
		HTTPAddr:      get("SIGNMIND_HTTP_ADDR", ":8080"),
		AIAddr:        get("SIGNMIND_AI_ADDR", "localhost:50051"),
		Env:           env,
		DBPath:        get("SIGNMIND_DB_PATH", "data/predictions.db"),
		JWTSecret:     get("SIGNMIND_JWT_SECRET", ""),
		AdminEmail:    get("SIGNMIND_ADMIN_EMAIL", ""),
		AdminPassword: get("SIGNMIND_ADMIN_PASSWORD", ""),
		AllowSignup:   strings.EqualFold(get("SIGNMIND_ALLOW_SIGNUP", "true"), "true"),
		TrustProxy:    strings.EqualFold(get("SIGNMIND_TRUST_PROXY", "false"), "true"),
	}
}

// parseDotEnv reads KEY=VALUE lines. Missing file -> empty map (the file is
// optional); malformed lines are skipped. Keys are uppercased so `env=Dev`
// and `ENV=Dev` mean the same thing.
func parseDotEnv(path string) map[string]string {
	vars := map[string]string{}
	data, err := os.ReadFile(path)
	if err != nil {
		return vars
	}
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.ToUpper(strings.TrimSpace(key))
		value = strings.TrimSpace(value)
		value = strings.Trim(value, `"'`)
		if key != "" {
			vars[key] = value
		}
	}
	return vars
}
