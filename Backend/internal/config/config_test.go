package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestDefaultsAreProd(t *testing.T) {
	cfg := load(nil)
	if cfg.Env != EnvProd || cfg.IsDev() {
		t.Fatalf("expected Prod default, got %q", cfg.Env)
	}
	if cfg.HTTPAddr != ":8080" || cfg.AIAddr != "localhost:50051" {
		t.Fatalf("unexpected defaults: %+v", cfg)
	}
	if cfg.DBPath != "data/predictions.db" {
		t.Fatalf("unexpected DB path: %q", cfg.DBPath)
	}
}

func TestDotEnvValuesApply(t *testing.T) {
	cfg := load(map[string]string{"ENV": "Dev", "SIGNMIND_HTTP_ADDR": ":9999"})
	if !cfg.IsDev() {
		t.Fatalf("expected Dev, got %q", cfg.Env)
	}
	if cfg.HTTPAddr != ":9999" {
		t.Fatalf("expected .env addr override, got %q", cfg.HTTPAddr)
	}
}

func TestRealEnvBeatsDotEnv(t *testing.T) {
	t.Setenv("ENV", "Prod")
	cfg := load(map[string]string{"ENV": "Dev"})
	if cfg.Env != EnvProd {
		t.Fatalf("process env must win, got %q", cfg.Env)
	}
}

func TestUnknownEnvFailsSafeToProd(t *testing.T) {
	cfg := load(map[string]string{"ENV": "staging"})
	if cfg.Env != EnvProd {
		t.Fatalf("unknown ENV must fall back to Prod, got %q", cfg.Env)
	}
}

func TestParseDotEnv(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".env")
	content := "# comment\n\nenv=Dev\nSIGNMIND_AI_ADDR = \"host:1234\" \nbroken-line\n"
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	vars := parseDotEnv(path)
	if vars["ENV"] != "Dev" { // lowercase key uppercased
		t.Fatalf("expected ENV=Dev, got %v", vars)
	}
	if vars["SIGNMIND_AI_ADDR"] != "host:1234" {
		t.Fatalf("expected quoted value trimmed, got %v", vars)
	}
	if _, ok := vars["BROKEN-LINE"]; ok {
		t.Fatalf("line without '=' must be skipped: %v", vars)
	}
}

func TestMissingFileIsEmpty(t *testing.T) {
	vars := parseDotEnv(filepath.Join(t.TempDir(), "absent.env"))
	if len(vars) != 0 {
		t.Fatalf("expected empty map, got %v", vars)
	}
}
