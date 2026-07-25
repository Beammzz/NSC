package llm

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"
	"unicode/utf8"
)

// Result is one finished composition. Sentence is always usable: on any
// failure it falls back to the raw glosses joined together and Fallback is
// true, so a broken or unconfigured LLM never costs the user their sentence.
type Result struct {
	Sentence  string `json:"sentence"`
	Fallback  bool   `json:"fallback"`
	LatencyMS int64  `json:"latency_ms"`
	Error     string `json:"error,omitempty"`
}

// BufferPolicy tells the stream handler how long a signing pause must be
// before the buffered words are composed, and how many words may accumulate
// before it flushes early. There is no "off" here on purpose: with the LLM
// unconfigured Compose still returns RawJoin, and the client still needs the
// end-of-sentence signal to speak.
type BufferPolicy struct {
	Silence  time.Duration
	MaxWords int
}

// Service composes sentences through an OpenAI-compatible chat completions
// endpoint and logs every attempt.
type Service struct {
	store  *Store
	client *http.Client
}

func NewService(store *Store) *Service {
	return &Service{store: store, client: &http.Client{}}
}

// Policy reads the current buffering configuration, falling back to the
// defaults when the settings cannot be read.
func (s *Service) Policy() BufferPolicy {
	settings, err := s.store.GetSettings()
	if err != nil {
		settings = DefaultSettings()
	}
	return BufferPolicy{
		// silence_ms -> nanoseconds (time.Duration's unit).
		Silence:  time.Duration(settings.SilenceMS) * time.Millisecond,
		MaxWords: settings.MaxWords,
	}
}

// RawJoin is the fallback sentence: Thai is written without spaces between
// words, so concatenating the glosses is already readable ("ฉัน รัก เธอ" ->
// "ฉันรักเธอ") and never invents meaning.
func RawJoin(words []string) string {
	var b strings.Builder
	for _, w := range words {
		b.WriteString(strings.TrimSpace(w))
	}
	return b.String()
}

// ---- OpenAI-compatible wire types ----

type chatMessage struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatRequest struct {
	Model       string        `json:"model"`
	Messages    []chatMessage `json:"messages"`
	Temperature float64       `json:"temperature"`
	Stream      bool          `json:"stream"`
}

type chatResponse struct {
	Choices []struct {
		Message chatMessage `json:"message"`
	} `json:"choices"`
	Error *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// Compose turns the buffered glosses into one Thai sentence. It never returns
// an error: every failure path degrades to RawJoin and is recorded in the
// result and the log.
func (s *Service) Compose(ctx context.Context, words []string) Result {
	fallback := RawJoin(words)
	if len(words) == 0 {
		return Result{Sentence: "", Fallback: true}
	}

	settings, err := s.store.GetSettings()
	if err != nil {
		return s.logged(words, Result{
			Sentence: fallback, Fallback: true,
			Error: "reading llm settings: " + err.Error(),
		}, "", "")
	}
	if !settings.Enabled || settings.APIKey == "" || settings.Endpoint == "" {
		// Not an attempt — nothing to audit, so this one is not logged.
		return Result{Sentence: fallback, Fallback: true, Error: "llm disabled"}
	}

	started := time.Now()
	raw, err := s.call(ctx, settings, words)
	latencyMS := time.Since(started).Milliseconds()
	if err != nil {
		return s.logged(words, Result{
			Sentence: fallback, Fallback: true, LatencyMS: latencyMS,
			Error: err.Error(),
		}, raw, settings.Model)
	}

	sentence, err := validate(raw, words)
	if err != nil {
		return s.logged(words, Result{
			Sentence: fallback, Fallback: true, LatencyMS: latencyMS,
			Error: err.Error(),
		}, raw, settings.Model)
	}
	return s.logged(words, Result{
		Sentence: sentence, Fallback: false, LatencyMS: latencyMS,
	}, raw, settings.Model)
}

// call performs one chat completion and returns the assistant's raw content.
func (s *Service) call(ctx context.Context, settings Settings, words []string) (string, error) {
	// timeout_ms -> nanoseconds (time.Duration's unit).
	ctx, cancel := context.WithTimeout(ctx, time.Duration(settings.TimeoutMS)*time.Millisecond)
	defer cancel()

	body, err := json.Marshal(chatRequest{
		Model: settings.Model,
		Messages: []chatMessage{
			{Role: "system", Content: settings.SystemPrompt},
			{Role: "user", Content: strings.Join(words, " ")},
		},
		Temperature: settings.Temperature,
		Stream:      false,
	})
	if err != nil {
		return "", fmt.Errorf("encoding chat request: %w", err)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, settings.Endpoint, bytes.NewReader(body))
	if err != nil {
		return "", fmt.Errorf("building chat request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+settings.APIKey)

	resp, err := s.client.Do(req)
	if err != nil {
		return "", fmt.Errorf("calling llm endpoint: %w", err)
	}
	defer resp.Body.Close()

	// Cap the read: a misconfigured endpoint can return an unbounded body.
	payload, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", fmt.Errorf("reading llm response: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode > 299 {
		return string(payload), fmt.Errorf("llm endpoint returned %d: %s",
			resp.StatusCode, snippet(string(payload), 200))
	}

	var parsed chatResponse
	if err := json.Unmarshal(payload, &parsed); err != nil {
		return string(payload), fmt.Errorf("decoding llm response: %w", err)
	}
	if parsed.Error != nil && parsed.Error.Message != "" {
		return string(payload), fmt.Errorf("llm endpoint error: %s", parsed.Error.Message)
	}
	if len(parsed.Choices) == 0 {
		return string(payload), fmt.Errorf("llm response contained no choices")
	}
	return parsed.Choices[0].Message.Content, nil
}

// validate turns raw model output into a usable sentence, or reports why it
// cannot be trusted. The in-vocab rule is the safety net from the TSL grammar
// research: the model may reorder and insert function words, but a recognized
// gloss that vanished from the output means it rewrote what the signer said.
func validate(raw string, words []string) (string, error) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return "", fmt.Errorf("llm returned an empty sentence")
	}

	// Strip a fenced block: ```\n<sentence>\n``` (or ```text\n...).
	if strings.HasPrefix(text, "```") {
		if idx := strings.Index(text, "\n"); idx >= 0 {
			text = text[idx+1:]
		}
		text = strings.TrimSuffix(strings.TrimSpace(text), "```")
	}

	// One sentence only: keep the first non-empty line.
	for line := range strings.SplitSeq(text, "\n") {
		if strings.TrimSpace(line) != "" {
			text = line
			break
		}
	}
	// Cutset is a rune set, so the multi-byte quote marks are handled.
	text = strings.Trim(strings.TrimSpace(text), "\"'`“”‘’「」 ")
	if text == "" {
		return "", fmt.Errorf("llm returned an empty sentence")
	}

	// Length guard against a runaway explanation. Rune counts, not bytes:
	// Thai characters are 3 bytes each.
	inputRunes := utf8.RuneCountInString(RawJoin(words))
	if utf8.RuneCountInString(text) > inputRunes*4+60 {
		return "", fmt.Errorf("llm sentence is implausibly long (%d runes for %d input runes)",
			utf8.RuneCountInString(text), inputRunes)
	}

	for _, w := range words {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		if !strings.Contains(text, w) {
			return "", fmt.Errorf("llm sentence dropped the recognized word %q", w)
		}
	}
	return text, nil
}

// logged records the attempt and returns res unchanged; a failing log write
// must never cost the caller its sentence.
func (s *Service) logged(words []string, res Result, raw, model string) Result {
	err := s.store.InsertLog(LogRecord{
		Words:     words,
		Sentence:  res.Sentence,
		Raw:       snippet(raw, 2000),
		Model:     model,
		LatencyMS: res.LatencyMS,
		OK:        res.Error == "",
		Fallback:  res.Fallback,
		Error:     res.Error,
	})
	if err != nil {
		// Surfaced through the server log only: the sentence still ships.
		log.Printf("llm: writing request log: %v", err)
	}
	return res
}

func snippet(s string, maxRunes int) string {
	if utf8.RuneCountInString(s) <= maxRunes {
		return s
	}
	return string([]rune(s)[:maxRunes]) + "…"
}
