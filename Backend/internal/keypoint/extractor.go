// Package keypoint turns a recorded sign clip into avatar keypoint frames by
// running the Python extract_keypoints.py CLI (MediaPipe pose+hand landmarks).
// Extraction is an offline, one-shot job — deliberately off the realtime gRPC
// landmark path — so the gateway simply execs the x64 Python interpreter.
package keypoint

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"time"
)

const defaultTimeout = 60 * time.Second

// ErrNotConfigured is returned when the extractor has no interpreter/script
// path set, so callers can reject recording uploads with a clear message.
var ErrNotConfigured = errors.New(
	"keypoint: extractor not configured (set SIGNMIND_KEYPOINT_PY and SIGNMIND_EXTRACT_SCRIPT)")

// Runner executes a command and returns its stdout; on failure the error must
// include stderr. exec.CommandContext is the production implementation; tests
// inject a fake so no Python runtime is needed.
type Runner interface {
	Run(ctx context.Context, name string, args ...string) (stdout []byte, err error)
}

// execRunner runs the command for real, surfacing stderr in the returned error.
type execRunner struct{}

func (execRunner) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, name, args...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%w: %s", err, stderr.String())
	}
	return stdout.Bytes(), nil
}

// Extractor invokes extract_keypoints.py to turn a clip into avatar keypoint
// frames (JSON: [[{x,y,z},...],...]).
type Extractor struct {
	python  string
	script  string
	frames  int
	timeout time.Duration
	runner  Runner
}

// New builds an Extractor. python is the (x64) interpreter with MediaPipe
// installed; script is the path to extract_keypoints.py; frames is how many
// frames to request (<=0 uses the script's own default).
func New(python, script string, frames int) *Extractor {
	return &Extractor{
		python:  python,
		script:  script,
		frames:  frames,
		timeout: defaultTimeout,
		runner:  execRunner{},
	}
}

// Configured reports whether both the interpreter and script paths are set.
func (e *Extractor) Configured() bool {
	return e != nil && e.python != "" && e.script != ""
}

// ExtractReader writes r to a temp file (preserving ext) and extracts from it,
// removing the temp file afterwards.
func (e *Extractor) ExtractReader(ctx context.Context, r io.Reader, ext string) (json.RawMessage, error) {
	if !e.Configured() {
		return nil, ErrNotConfigured
	}
	if ext == "" {
		ext = ".webm"
	}
	tmp, err := os.CreateTemp("", "signmind-rec-*"+ext)
	if err != nil {
		return nil, fmt.Errorf("keypoint: temp file: %w", err)
	}
	tmpPath := tmp.Name()
	defer os.Remove(tmpPath)
	if _, err := io.Copy(tmp, r); err != nil {
		tmp.Close()
		return nil, fmt.Errorf("keypoint: writing upload: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return nil, fmt.Errorf("keypoint: closing temp: %w", err)
	}
	return e.Extract(ctx, tmpPath)
}

// Extract runs the CLI over an existing video file and returns validated
// keypoint-frame JSON.
func (e *Extractor) Extract(ctx context.Context, videoPath string) (json.RawMessage, error) {
	if !e.Configured() {
		return nil, ErrNotConfigured
	}
	ctx, cancel := context.WithTimeout(ctx, e.timeout)
	defer cancel()

	args := []string{e.script, videoPath}
	if e.frames > 0 {
		args = append(args, "--frames", strconv.Itoa(e.frames))
	}
	out, err := e.runner.Run(ctx, e.python, args...)
	if err != nil {
		return nil, fmt.Errorf("keypoint extraction failed: %w", err)
	}
	return validateFrames(out)
}

// validateFrames ensures the CLI emitted a non-empty JSON array of {x,y,z}
// frames, then returns the raw bytes for storage.
func validateFrames(out []byte) (json.RawMessage, error) {
	var frames [][]struct {
		X float64 `json:"x"`
		Y float64 `json:"y"`
		Z float64 `json:"z"`
	}
	if err := json.Unmarshal(out, &frames); err != nil {
		return nil, fmt.Errorf("keypoint: unparseable CLI output: %w", err)
	}
	if len(frames) == 0 {
		return nil, errors.New("keypoint: extractor returned no frames")
	}
	return json.RawMessage(out), nil
}
