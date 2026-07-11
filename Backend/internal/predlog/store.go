// Package predlog persists every prediction the AI service returns so the
// webui can browse and analyze them (SQLite via the pure-Go modernc driver).
package predlog

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	_ "modernc.org/sqlite" // database/sql driver "sqlite"
)

const schema = `
CREATE TABLE IF NOT EXISTS predictions (
	id               INTEGER PRIMARY KEY AUTOINCREMENT,
	created_ms       INTEGER NOT NULL,
	seq              INTEGER NOT NULL,
	word             TEXT    NOT NULL,
	confidence       REAL    NOT NULL,
	is_idle          INTEGER NOT NULL,
	is_uncertain     INTEGER NOT NULL,
	inference_micros INTEGER NOT NULL,
	other_prob       REAL    NOT NULL,
	top_json         TEXT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_predictions_created ON predictions(created_ms);
CREATE INDEX IF NOT EXISTS idx_predictions_word ON predictions(word);
`

// ClassProb mirrors the proto ClassProb for storage/JSON.
type ClassProb struct {
	Label string  `json:"label"`
	Prob  float64 `json:"prob"`
}

// Record is one logged prediction. Top/OtherProb carry the full breakdown
// only when the AI service runs in debug_mode (Dev).
type Record struct {
	ID              int64       `json:"id"`
	CreatedMS       int64       `json:"created_ms"`
	Seq             uint64      `json:"seq"`
	Word            string      `json:"word"`
	Confidence      float64     `json:"confidence"`
	IsIdle          bool        `json:"is_idle"`
	IsUncertain     bool        `json:"is_uncertain"`
	InferenceMicros int64       `json:"inference_micros"`
	OtherProb       float64     `json:"other_prob"`
	Top             []ClassProb `json:"top"`
}

// QueryOptions filter List. Zero values mean "no filter"; Limit 0 means the
// default page size.
type QueryOptions struct {
	Word    string // exact word match
	SinceMS int64  // created_ms >= SinceMS
	Limit   int
	Offset  int
}

const (
	defaultLimit = 100
	maxLimit     = 1000
)

type Store struct {
	db *sql.DB
}

// Open creates parent directories, opens/creates the database, and applies
// the schema. WAL + busy_timeout keep the single-writer model responsive
// while the webui reads.
func Open(path string) (*Store, error) {
	if dir := filepath.Dir(path); dir != "." && dir != "" {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return nil, fmt.Errorf("creating prediction log dir: %w", err)
		}
	}
	dsn := "file:" + filepath.ToSlash(path) +
		"?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)"
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("opening prediction log: %w", err)
	}
	if _, err := db.Exec(schema); err != nil {
		db.Close()
		return nil, fmt.Errorf("migrating prediction log: %w", err)
	}
	return &Store{db: db}, nil
}

// OpenWith applies the prediction schema to an existing *sql.DB. The caller
// owns the DB lifetime (Close is a no-op on a shared DB).
func OpenWith(db *sql.DB) (*Store, error) {
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("migrating prediction log: %w", err)
	}
	return &Store{db: db}, nil
}

func (s *Store) Close() error { return s.db.Close() }

// Insert logs one prediction. A zero CreatedMS is stamped with the current
// time.
func (s *Store) Insert(r Record) error {
	if r.CreatedMS == 0 {
		r.CreatedMS = time.Now().UnixMilli()
	}
	top := r.Top
	if top == nil {
		top = []ClassProb{}
	}
	topJSON, err := json.Marshal(top)
	if err != nil {
		return fmt.Errorf("encoding top list: %w", err)
	}
	_, err = s.db.Exec(
		`INSERT INTO predictions
		 (created_ms, seq, word, confidence, is_idle, is_uncertain,
		  inference_micros, other_prob, top_json)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		r.CreatedMS, int64(r.Seq), r.Word, r.Confidence, r.IsIdle,
		r.IsUncertain, r.InferenceMicros, r.OtherProb, string(topJSON),
	)
	if err != nil {
		return fmt.Errorf("inserting prediction: %w", err)
	}
	return nil
}

// List returns matching records, newest first.
func (s *Store) List(opts QueryOptions) ([]Record, error) {
	limit := opts.Limit
	if limit <= 0 {
		limit = defaultLimit
	}
	if limit > maxLimit {
		limit = maxLimit
	}
	query := `SELECT id, created_ms, seq, word, confidence, is_idle,
	                 is_uncertain, inference_micros, other_prob, top_json
	          FROM predictions WHERE 1=1`
	args := []any{}
	if opts.Word != "" {
		query += " AND word = ?"
		args = append(args, opts.Word)
	}
	if opts.SinceMS > 0 {
		query += " AND created_ms >= ?"
		args = append(args, opts.SinceMS)
	}
	query += " ORDER BY id DESC LIMIT ? OFFSET ?"
	args = append(args, limit, opts.Offset)

	rows, err := s.db.Query(query, args...)
	if err != nil {
		return nil, fmt.Errorf("querying predictions: %w", err)
	}
	defer rows.Close()

	records := []Record{}
	for rows.Next() {
		var r Record
		var seq int64
		var topJSON string
		if err := rows.Scan(
			&r.ID, &r.CreatedMS, &seq, &r.Word, &r.Confidence, &r.IsIdle,
			&r.IsUncertain, &r.InferenceMicros, &r.OtherProb, &topJSON,
		); err != nil {
			return nil, fmt.Errorf("scanning prediction: %w", err)
		}
		r.Seq = uint64(seq)
		if err := json.Unmarshal([]byte(topJSON), &r.Top); err != nil {
			return nil, fmt.Errorf("decoding top list of record %d: %w", r.ID, err)
		}
		records = append(records, r)
	}
	return records, rows.Err()
}

// Count returns the total number of logged predictions.
func (s *Store) Count() (int64, error) {
	var n int64
	err := s.db.QueryRow(`SELECT COUNT(*) FROM predictions`).Scan(&n)
	if err != nil {
		return 0, fmt.Errorf("counting predictions: %w", err)
	}
	return n, nil
}
