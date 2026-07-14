package keypoint

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
)

// fakeRunner records the command it was asked to run and returns canned output.
type fakeRunner struct {
	out     []byte
	err     error
	gotName string
	gotArgs []string
}

func (f *fakeRunner) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	f.gotName = name
	f.gotArgs = args
	return f.out, f.err
}

func TestExtractPassesArgsAndReturnsFrames(t *testing.T) {
	const payload = `[[{"x":0.1,"y":0.2,"z":0}]]`
	fr := &fakeRunner{out: []byte(payload)}
	e := &Extractor{python: "py", script: "extract_keypoints.py", frames: 12, runner: fr}

	raw, err := e.Extract(context.Background(), "clip.webm")
	if err != nil {
		t.Fatalf("Extract: %v", err)
	}
	if string(raw) != payload {
		t.Errorf("raw = %s, want %s", raw, payload)
	}
	if fr.gotName != "py" {
		t.Errorf("interpreter = %q, want py", fr.gotName)
	}
	want := []string{"extract_keypoints.py", "clip.webm", "--frames", "12"}
	if strings.Join(fr.gotArgs, " ") != strings.Join(want, " ") {
		t.Errorf("args = %v, want %v", fr.gotArgs, want)
	}
}

func TestExtractOmitsFramesFlagWhenZero(t *testing.T) {
	fr := &fakeRunner{out: []byte(`[[{"x":0,"y":0,"z":0}]]`)}
	e := &Extractor{python: "py", script: "s.py", runner: fr}
	if _, err := e.Extract(context.Background(), "c.webm"); err != nil {
		t.Fatal(err)
	}
	for _, a := range fr.gotArgs {
		if a == "--frames" {
			t.Errorf("--frames must be omitted when frames<=0: %v", fr.gotArgs)
		}
	}
}

func TestExtractRejectsEmptyFrames(t *testing.T) {
	fr := &fakeRunner{out: []byte(`[]`)}
	e := &Extractor{python: "py", script: "s.py", runner: fr}
	if _, err := e.Extract(context.Background(), "c.webm"); err == nil {
		t.Fatal("expected an error for an empty frame array")
	}
}

func TestExtractRejectsBadJSON(t *testing.T) {
	fr := &fakeRunner{out: []byte("not json")}
	e := &Extractor{python: "py", script: "s.py", runner: fr}
	if _, err := e.Extract(context.Background(), "c.webm"); err == nil {
		t.Fatal("expected an error for unparseable output")
	}
}

func TestExtractWrapsRunnerError(t *testing.T) {
	fr := &fakeRunner{err: errors.New("python traceback")}
	e := &Extractor{python: "py", script: "s.py", runner: fr}
	if _, err := e.Extract(context.Background(), "c.webm"); err == nil {
		t.Fatal("expected the runner error to propagate")
	}
}

func TestExtractNotConfigured(t *testing.T) {
	e := New("", "", 0)
	if _, err := e.Extract(context.Background(), "c.webm"); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("want ErrNotConfigured, got %v", err)
	}
}

func TestConfigured(t *testing.T) {
	if New("", "", 0).Configured() {
		t.Error("empty paths should not be configured")
	}
	if !New("py", "s.py", 0).Configured() {
		t.Error("both paths set should be configured")
	}
	var nilExtractor *Extractor
	if nilExtractor.Configured() {
		t.Error("nil extractor should not be configured")
	}
}

func TestExtractReaderWritesTempAndCleansUp(t *testing.T) {
	fr := &fakeRunner{out: []byte(`[[{"x":0,"y":0,"z":0}]]`)}
	e := &Extractor{python: "py", script: "s.py", runner: fr}

	raw, err := e.ExtractReader(context.Background(), strings.NewReader("fake video bytes"), ".webm")
	if err != nil {
		t.Fatalf("ExtractReader: %v", err)
	}
	if len(raw) == 0 {
		t.Error("expected non-empty frames JSON")
	}
	// The video path is arg[1]; the temp file must be gone after the call.
	if len(fr.gotArgs) < 2 {
		t.Fatalf("runner args = %v", fr.gotArgs)
	}
	tmpPath := fr.gotArgs[1]
	if !strings.HasSuffix(tmpPath, ".webm") {
		t.Errorf("temp path %q lost its extension", tmpPath)
	}
	if _, err := os.Stat(tmpPath); !os.IsNotExist(err) {
		t.Errorf("temp file not cleaned up: %v (stat err %v)", tmpPath, err)
	}
}
