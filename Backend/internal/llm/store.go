// Package llm turns the run of TSL words recognized during one signing burst
// into a single natural Thai sentence, through an OpenAI-compatible chat
// completions endpoint (Typhoon by default). Settings and a log of every
// request live in the shared SQLite database (pure-Go modernc driver) so the
// admin webui can edit and audit them.
package llm

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	_ "modernc.org/sqlite" // database/sql driver "sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS llm_settings (
	key   TEXT PRIMARY KEY,
	value TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS llm_logs (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	created_ms INTEGER NOT NULL,
	words_json TEXT    NOT NULL,
	sentence   TEXT    NOT NULL,
	raw        TEXT    NOT NULL,
	model      TEXT    NOT NULL,
	latency_ms INTEGER NOT NULL,
	ok         INTEGER NOT NULL,
	fallback   INTEGER NOT NULL,
	error      TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_llm_logs_created ON llm_logs(created_ms);
`

// Defaults for a fresh install. Endpoint and model are Typhoon's (SCB DataX),
// the Thai-native provider chosen for this path; any OpenAI-compatible
// /chat/completions endpoint works.
const (
	DefaultEndpoint    = "https://api.opentyphoon.ai/v1/chat/completions"
	DefaultModel       = "typhoon-v2.5-30b-a3b-instruct"
	DefaultSilenceMS   = 2000
	DefaultMaxWords    = 12
	DefaultTimeoutMS   = 8000
	DefaultTemperature = 0.2
)

// DefaultSystemPrompt encodes the two hard safety rules from the TSL grammar
// research (docs/STATE.md): the model may reorder and insert function words,
// but it may never invent or drop meaning — negation and yes/no questions are
// invisible to a hands+pose recognizer, so guessing them changes what the
// signer said.
const DefaultSystemPrompt = `คุณคือระบบเรียบเรียงประโยคภาษาไทยจากภาษามือไทย (TSL)
ผู้ใช้จะส่งลำดับคำศัพท์ (gloss) ที่ระบบจดจำท่ามือได้ คั่นด้วยช่องว่าง
หน้าที่ของคุณคือเรียบเรียงคำเหล่านั้นให้เป็นประโยคภาษาไทยที่เป็นธรรมชาติเพียงประโยคเดียว

กติกา:
1. ใช้คำศัพท์ที่ได้รับให้ครบทุกคำ ห้ามตัดคำใดทิ้ง
2. เขียนภาษาไทยติดกันตามปกติ ไม่ต้องเว้นวรรคระหว่างคำ
3. สลับลำดับได้เมื่อโครงสร้าง topic-comment ของภาษามือต้องการ
4. เติมได้เฉพาะคำหน้าที่ (ที่ ใน บน ด้วย กับ เป็น คือ อยู่ จะ แล้ว กำลัง ลักษณนาม คำสุภาพ)
5. ห้ามเติมความหมายใหม่ ห้ามเติมคำปฏิเสธ (ไม่ ไม่ได้) และห้ามเปลี่ยนประโยคบอกเล่าเป็นคำถาม
   ถ้าไม่มีคำปฏิเสธหรือคำถามในลำดับที่ได้รับ ประโยคผลลัพธ์ต้องไม่มีเช่นกัน
6. ตอบกลับเป็นประโยคเดียวเท่านั้น ห้ามอธิบาย ห้ามใส่เครื่องหมายคำพูดหรือ markdown`

// Settings is the full LLM configuration. APIKey is stored in the clear in
// the server-side database; the admin API masks it on read.
type Settings struct {
	Enabled          bool    `json:"enabled"`
	Endpoint         string  `json:"endpoint"`
	APIKey           string  `json:"api_key"`
	Model            string  `json:"model"`
	SystemPrompt     string  `json:"system_prompt"`
	SilenceMS        int     `json:"silence_ms"`
	MaxWords         int     `json:"max_words"`
	TimeoutMS        int     `json:"timeout_ms"`
	Temperature      float64 `json:"temperature"`
	AutoCleanMaxLogs int64   `json:"auto_clean_max_logs"`
}

// SettingsPatch is a partial update: a nil field is left unchanged. An empty
// APIKey pointer value clears the key.
type SettingsPatch struct {
	Enabled          *bool    `json:"enabled"`
	Endpoint         *string  `json:"endpoint"`
	APIKey           *string  `json:"api_key"`
	Model            *string  `json:"model"`
	SystemPrompt     *string  `json:"system_prompt"`
	SilenceMS        *int     `json:"silence_ms"`
	MaxWords         *int     `json:"max_words"`
	TimeoutMS        *int     `json:"timeout_ms"`
	Temperature      *float64 `json:"temperature"`
	AutoCleanMaxLogs *int64   `json:"auto_clean_max_logs"`
}

// LogRecord is one composition attempt. Raw keeps the unvalidated model
// output so an admin can see why a response was rejected.
type LogRecord struct {
	ID        int64    `json:"id"`
	CreatedMS int64    `json:"created_ms"`
	Words     []string `json:"words"`
	Sentence  string   `json:"sentence"`
	Raw       string   `json:"raw"`
	Model     string   `json:"model"`
	LatencyMS int64    `json:"latency_ms"`
	OK        bool     `json:"ok"`
	Fallback  bool     `json:"fallback"`
	Error     string   `json:"error"`
}

// QueryOptions filter ListLogs. Limit 0 means the default page size.
type QueryOptions struct {
	Limit  int
	Offset int
}

const (
	defaultLimit = 100
	maxLimit     = 1000
)

type Store struct {
	db *sql.DB
}

// Open creates parent directories, opens/creates the database, and applies
// the schema. Mirrors predlog.Open (WAL + busy_timeout).
func Open(path string) (*Store, error) {
	if dir := filepath.Dir(path); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("creating llm store dir: %w", err)
		}
	}
	dsn := "file:" + filepath.ToSlash(path) +
		"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("opening llm store: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrating llm store: %w", err)
	}
	return &Store{db: db}, nil
}

// OpenWith applies the llm schema to an existing *sql.DB. The caller owns the
// DB lifetime.
func OpenWith(db *sql.DB) (*Store, error) {
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("migrating llm store: %w", err)
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

// ---- settings ----

const (
	keyEnabled          = "enabled"
	keyEndpoint         = "endpoint"
	keyAPIKey           = "api_key"
	keyModel            = "model"
	keySystemPrompt     = "system_prompt"
	keySilenceMS        = "silence_ms"
	keyMaxWords         = "max_words"
	keyTimeoutMS        = "timeout_ms"
	keyTemperature      = "temperature"
	keyAutoCleanMaxLogs = "auto_clean_max_logs"
)

// DefaultSettings is the configuration used before an admin saves anything.
func DefaultSettings() Settings {
	return Settings{
		Enabled:          false,
		Endpoint:         DefaultEndpoint,
		APIKey:           "",
		Model:            DefaultModel,
		SystemPrompt:     DefaultSystemPrompt,
		SilenceMS:        DefaultSilenceMS,
		MaxWords:         DefaultMaxWords,
		TimeoutMS:        DefaultTimeoutMS,
		Temperature:      DefaultTemperature,
		AutoCleanMaxLogs: 0,
	}
}

// GetSettings returns the stored configuration, with defaults for any key the
// admin has never saved.
func (s *Store) GetSettings() (Settings, error) {
	out := DefaultSettings()
	rows, err := s.db.Query(`SELECT key, value FROM llm_settings`)
	if err != nil {
		return out, fmt.Errorf("reading llm settings: %w", err)
	}
	defer rows.Close()
	for rows.Next() {
		var key, value string
		if err := rows.Scan(&key, &value); err != nil {
			return out, fmt.Errorf("scanning llm setting: %w", err)
		}
		switch key {
		case keyEnabled:
			out.Enabled = value == "true"
		case keyEndpoint:
			out.Endpoint = value
		case keyAPIKey:
			out.APIKey = value
		case keyModel:
			out.Model = value
		case keySystemPrompt:
			out.SystemPrompt = value
		case keySilenceMS:
			if n, err := strconv.Atoi(value); err == nil {
				out.SilenceMS = n
			}
		case keyMaxWords:
			if n, err := strconv.Atoi(value); err == nil {
				out.MaxWords = n
			}
		case keyTimeoutMS:
			if n, err := strconv.Atoi(value); err == nil {
				out.TimeoutMS = n
			}
		case keyTemperature:
			if f, err := strconv.ParseFloat(value, 64); err == nil {
				out.Temperature = f
			}
		case keyAutoCleanMaxLogs:
			if n, err := strconv.ParseInt(value, 10, 64); err == nil {
				out.AutoCleanMaxLogs = n
			}
		}
	}
	if err := rows.Err(); err != nil {
		return out, fmt.Errorf("reading llm settings: %w", err)
	}
	return clampSettings(out), nil
}

// clampSettings keeps stored values inside ranges the composer can act on;
// a zero or negative window would flush on every prediction.
func clampSettings(s Settings) Settings {
	if s.SilenceMS < 200 {
		s.SilenceMS = 200
	}
	if s.SilenceMS > 30000 {
		s.SilenceMS = 30000
	}
	if s.MaxWords < 1 {
		s.MaxWords = 1
	}
	if s.MaxWords > 64 {
		s.MaxWords = 64
	}
	if s.TimeoutMS < 500 {
		s.TimeoutMS = 500
	}
	if s.TimeoutMS > 120000 {
		s.TimeoutMS = 120000
	}
	if s.Temperature < 0 {
		s.Temperature = 0
	}
	if s.Temperature > 2 {
		s.Temperature = 2
	}
	if s.AutoCleanMaxLogs < 0 {
		s.AutoCleanMaxLogs = 0
	}
	return s
}

// SaveSettings applies a partial update and returns the resulting settings.
func (s *Store) SaveSettings(p SettingsPatch) (Settings, error) {
	writes := map[string]string{}
	if p.Enabled != nil {
		writes[keyEnabled] = strconv.FormatBool(*p.Enabled)
	}
	if p.Endpoint != nil {
		writes[keyEndpoint] = *p.Endpoint
	}
	if p.APIKey != nil {
		writes[keyAPIKey] = *p.APIKey
	}
	if p.Model != nil {
		writes[keyModel] = *p.Model
	}
	if p.SystemPrompt != nil {
		writes[keySystemPrompt] = *p.SystemPrompt
	}
	if p.SilenceMS != nil {
		writes[keySilenceMS] = strconv.Itoa(*p.SilenceMS)
	}
	if p.MaxWords != nil {
		writes[keyMaxWords] = strconv.Itoa(*p.MaxWords)
	}
	if p.TimeoutMS != nil {
		writes[keyTimeoutMS] = strconv.Itoa(*p.TimeoutMS)
	}
	if p.Temperature != nil {
		writes[keyTemperature] = strconv.FormatFloat(*p.Temperature, 'f', -1, 64)
	}
	if p.AutoCleanMaxLogs != nil {
		writes[keyAutoCleanMaxLogs] = strconv.FormatInt(*p.AutoCleanMaxLogs, 10)
	}

	for key, value := range writes {
		_, err := s.db.Exec(`INSERT INTO llm_settings (key, value) VALUES (?, ?)
			ON CONFLICT(key) DO UPDATE SET value = excluded.value`, key, value)
		if err != nil {
			return Settings{}, fmt.Errorf("saving llm setting %q: %w", key, err)
		}
	}
	return s.GetSettings()
}

// ---- request log ----

// InsertLog appends one composition attempt, then prunes when the auto-clean
// limit is set.
func (s *Store) InsertLog(r LogRecord) error {
	if r.CreatedMS == 0 {
		r.CreatedMS = time.Now().UnixMilli()
	}
	words := r.Words
	if words == nil {
		words = []string{}
	}
	wordsJSON, err := json.Marshal(words)
	if err != nil {
		return fmt.Errorf("encoding llm log words: %w", err)
	}
	_, err = s.db.Exec(
		`INSERT INTO llm_logs
		 (created_ms, words_json, sentence, raw, model, latency_ms, ok, fallback, error)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.CreatedMS, string(wordsJSON), r.Sentence, r.Raw, r.Model,
		r.LatencyMS, r.OK, r.Fallback, r.Error,
	)
	if err != nil {
		return fmt.Errorf("inserting llm log: %w", err)
	}
	if settings, err := s.GetSettings(); err == nil && settings.AutoCleanMaxLogs > 0 {
		_, _ = s.PruneLogs(settings.AutoCleanMaxLogs)
	}
	return nil
}

// PruneLogs retains only the newest maxRecords entries.
func (s *Store) PruneLogs(maxRecords int64) (int64, error) {
	if maxRecords <= 0 {
		return 0, nil
	}
	res, err := s.db.Exec(
		`DELETE FROM llm_logs WHERE id NOT IN (
			SELECT id FROM llm_logs ORDER BY id DESC LIMIT ?
		)`, maxRecords)
	if err != nil {
		return 0, fmt.Errorf("pruning llm logs: %w", err)
	}
	n, _ := res.RowsAffected()
	return n, nil
}

// ListLogs returns matching entries, newest first.
func (s *Store) ListLogs(opts QueryOptions) ([]LogRecord, error) {
	limit := opts.Limit
	if limit <= 0 {
		limit = defaultLimit
	}
	if limit > maxLimit {
		limit = maxLimit
	}
	rows, err := s.db.Query(
		`SELECT id, created_ms, words_json, sentence, raw, model, latency_ms,
		        ok, fallback, error
		 FROM llm_logs ORDER BY id DESC LIMIT ? OFFSET ?`, limit, opts.Offset)
	if err != nil {
		return nil, fmt.Errorf("querying llm logs: %w", err)
	}
	defer rows.Close()

	records := []LogRecord{}
	for rows.Next() {
		var r LogRecord
		var wordsJSON string
		if err := rows.Scan(
			&r.ID, &r.CreatedMS, &wordsJSON, &r.Sentence, &r.Raw, &r.Model,
			&r.LatencyMS, &r.OK, &r.Fallback, &r.Error,
		); err != nil {
			return nil, fmt.Errorf("scanning llm log: %w", err)
		}
		if err := json.Unmarshal([]byte(wordsJSON), &r.Words); err != nil {
			return nil, fmt.Errorf("decoding words of llm log %d: %w", r.ID, err)
		}
		records = append(records, r)
	}
	return records, rows.Err()
}

// CountLogs returns the total number of logged compositions.
func (s *Store) CountLogs() (int64, error) {
	var n int64
	if err := s.db.QueryRow(`SELECT COUNT(*) FROM llm_logs`).Scan(&n); err != nil {
		return 0, fmt.Errorf("counting llm logs: %w", err)
	}
	return n, nil
}

// ClearLogs deletes every logged composition.
func (s *Store) ClearLogs() error {
	if _, err := s.db.Exec(`DELETE FROM llm_logs`); err != nil {
		return fmt.Errorf("clearing llm logs: %w", err)
	}
	return nil
}
