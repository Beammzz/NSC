// Package learn owns the Learning tab data: the TSL dictionary, the
// exercise roadmap (topics -> perform-the-sign exercises), and per-user
// progress. Exercises and their pass-confidence thresholds are editable
// through the admin webui (/api/v1/admin/learn/*).
package learn

import (
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"
)

const schema = `
CREATE TABLE IF NOT EXISTS learn_topics (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	slug       TEXT    NOT NULL UNIQUE,
	title      TEXT    NOT NULL,
	icon       TEXT    NOT NULL DEFAULT '',
	sort_order INTEGER NOT NULL DEFAULT 0,
	published  INTEGER NOT NULL DEFAULT 1
);
CREATE TABLE IF NOT EXISTS learn_exercises (
	id              INTEGER PRIMARY KEY AUTOINCREMENT,
	topic_id        INTEGER NOT NULL REFERENCES learn_topics(id),
	word            TEXT    NOT NULL,
	sort_order      INTEGER NOT NULL DEFAULT 0,
	pass_confidence REAL    NOT NULL DEFAULT 0.8,
	published       INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS idx_learn_exercises_topic ON learn_exercises(topic_id);
CREATE TABLE IF NOT EXISTS learn_signs (
	word            TEXT PRIMARY KEY,
	category        TEXT NOT NULL DEFAULT '',
	keypoint_frames TEXT
);
CREATE TABLE IF NOT EXISTS learn_progress (
	user_id         INTEGER NOT NULL,
	exercise_id     INTEGER NOT NULL REFERENCES learn_exercises(id),
	best_confidence REAL    NOT NULL DEFAULT 0,
	passed          INTEGER NOT NULL DEFAULT 0,
	updated_ms      INTEGER NOT NULL,
	PRIMARY KEY (user_id, exercise_id)
);
-- Notes live in their own table rather than a learn_signs column so that
-- existing dictionary databases need no migration and the seeded dictionary
-- rows are never rewritten.
CREATE TABLE IF NOT EXISTS learn_sign_notes (
	word TEXT PRIMARY KEY,
	note TEXT NOT NULL DEFAULT ''
);
-- Append-only log of every practice try. Attempt/correct counts (the learner
-- summary and the admin analytics) are aggregated from here; learn_progress
-- keeps only the never-regressing best result.
CREATE TABLE IF NOT EXISTS learn_attempts (
	id          INTEGER PRIMARY KEY AUTOINCREMENT,
	user_id     INTEGER NOT NULL,
	exercise_id INTEGER NOT NULL,
	confidence  REAL    NOT NULL,
	passed      INTEGER NOT NULL,
	created_ms  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_learn_attempts_user ON learn_attempts(user_id, exercise_id);
CREATE INDEX IF NOT EXISTS idx_learn_attempts_exercise ON learn_attempts(exercise_id);
`

// Topic is one roadmap node grouping related exercises (e.g. food, greetings).
type Topic struct {
	ID        int64      `json:"id"`
	Slug      string     `json:"slug"`
	Title     string     `json:"title"`
	Icon      string     `json:"icon"`
	SortOrder int        `json:"sort_order"`
	Published bool       `json:"published"`
	Exercises []Exercise `json:"exercises"`
}

// Exercise is one perform-the-sign task: the learner must produce Word at
// PassConfidence or above (model top-1 confidence) to pass.
type Exercise struct {
	ID             int64   `json:"id"`
	TopicID        int64   `json:"topic_id"`
	Word           string  `json:"word"`
	SortOrder      int     `json:"sort_order"`
	PassConfidence float64 `json:"pass_confidence"`
	Published      bool    `json:"published"`
}

// Sign is one dictionary entry. KeypointFrames, when present, is the JSON
// avatar animation ([][]{x,y,z} frames); nil means the client renders a
// fallback.
// Note is the admin-written explanation shown on the example step before
// practice; empty when the admin has not written one.
type Sign struct {
	Word           string          `json:"word"`
	Category       string          `json:"category"`
	Note           string          `json:"note"`
	KeypointFrames json.RawMessage `json:"keypoint_frames,omitempty"`
	HasAnimation   bool            `json:"has_animation"`
}

// Progress is one user's best result on one exercise. Attempts and
// CorrectAttempts are aggregated from learn_attempts and, unlike
// BestConfidence/Passed, count every try including the failed ones.
type Progress struct {
	ExerciseID      int64   `json:"exercise_id"`
	BestConfidence  float64 `json:"best_confidence"`
	Passed          bool    `json:"passed"`
	Attempts        int     `json:"attempts"`
	CorrectAttempts int     `json:"correct_attempts"`
	UpdatedMS       int64   `json:"updated_ms"`
}

// ExerciseStats is the admin-facing rollup for one exercise across all users.
type ExerciseStats struct {
	ExerciseID      int64   `json:"exercise_id"`
	Word            string  `json:"word"`
	TopicTitle      string  `json:"topic_title"`
	Attempts        int     `json:"attempts"`
	CorrectAttempts int     `json:"correct_attempts"`
	Learners        int     `json:"learners"`
	LearnersPassed  int     `json:"learners_passed"`
	AvgConfidence   float64 `json:"avg_confidence"`
}

// ErrNotFound is returned when a topic/exercise/sign does not exist.
var ErrNotFound = errors.New("learn: not found")

// Store persists learning content and progress in the shared SQLite DB.
type Store struct {
	db *sql.DB
}

// OpenWith applies the learn schema to an existing *sql.DB. The caller owns
// the DB lifetime (same shared-DB model as predlog.OpenWith).
func OpenWith(db *sql.DB) (*Store, error) {
	if _, err := db.Exec(schema); err != nil {
		return nil, fmt.Errorf("migrating learn schema: %w", err)
	}
	return &Store{db: db}, nil
}

// ---- topics & exercises ----

// ListTopics returns topics ordered by sort_order with their exercises.
// When publishedOnly is set, unpublished topics and exercises are omitted.
func (s *Store) ListTopics(publishedOnly bool) ([]Topic, error) {
	topicQ := `SELECT id, slug, title, icon, sort_order, published FROM learn_topics`
	if publishedOnly {
		topicQ += ` WHERE published = 1`
	}
	topicQ += ` ORDER BY sort_order, id`

	rows, err := s.db.Query(topicQ)
	if err != nil {
		return nil, fmt.Errorf("listing topics: %w", err)
	}
	defer rows.Close()

	topics := []Topic{}
	index := map[int64]int{}
	for rows.Next() {
		var t Topic
		var pub int
		if err := rows.Scan(&t.ID, &t.Slug, &t.Title, &t.Icon, &t.SortOrder, &pub); err != nil {
			return nil, fmt.Errorf("scanning topic: %w", err)
		}
		t.Published = pub != 0
		t.Exercises = []Exercise{}
		index[t.ID] = len(topics)
		topics = append(topics, t)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing topics: %w", err)
	}

	exQ := `SELECT id, topic_id, word, sort_order, pass_confidence, published FROM learn_exercises`
	if publishedOnly {
		exQ += ` WHERE published = 1`
	}
	exQ += ` ORDER BY sort_order, id`

	exRows, err := s.db.Query(exQ)
	if err != nil {
		return nil, fmt.Errorf("listing exercises: %w", err)
	}
	defer exRows.Close()
	for exRows.Next() {
		var e Exercise
		var pub int
		if err := exRows.Scan(&e.ID, &e.TopicID, &e.Word, &e.SortOrder, &e.PassConfidence, &pub); err != nil {
			return nil, fmt.Errorf("scanning exercise: %w", err)
		}
		e.Published = pub != 0
		if i, ok := index[e.TopicID]; ok {
			topics[i].Exercises = append(topics[i].Exercises, e)
		}
	}
	if err := exRows.Err(); err != nil {
		return nil, fmt.Errorf("listing exercises: %w", err)
	}
	return topics, nil
}

// CreateTopic inserts a topic and returns it with its assigned ID.
func (s *Store) CreateTopic(t Topic) (Topic, error) {
	res, err := s.db.Exec(
		`INSERT INTO learn_topics (slug, title, icon, sort_order, published) VALUES (?, ?, ?, ?, ?)`,
		t.Slug, t.Title, t.Icon, t.SortOrder, boolInt(t.Published))
	if err != nil {
		return Topic{}, fmt.Errorf("creating topic: %w", err)
	}
	t.ID, _ = res.LastInsertId()
	t.Exercises = []Exercise{}
	return t, nil
}

// UpdateTopic overwrites the editable fields of an existing topic.
func (s *Store) UpdateTopic(t Topic) error {
	res, err := s.db.Exec(
		`UPDATE learn_topics SET slug = ?, title = ?, icon = ?, sort_order = ?, published = ? WHERE id = ?`,
		t.Slug, t.Title, t.Icon, t.SortOrder, boolInt(t.Published), t.ID)
	if err != nil {
		return fmt.Errorf("updating topic: %w", err)
	}
	return checkFound(res)
}

// DeleteTopic removes a topic, its exercises, and progress on them.
func (s *Store) DeleteTopic(id int64) error {
	if _, err := s.db.Exec(
		`DELETE FROM learn_progress WHERE exercise_id IN (SELECT id FROM learn_exercises WHERE topic_id = ?)`, id); err != nil {
		return fmt.Errorf("deleting topic progress: %w", err)
	}
	if _, err := s.db.Exec(`DELETE FROM learn_exercises WHERE topic_id = ?`, id); err != nil {
		return fmt.Errorf("deleting topic exercises: %w", err)
	}
	res, err := s.db.Exec(`DELETE FROM learn_topics WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("deleting topic: %w", err)
	}
	return checkFound(res)
}

// GetExercise returns one exercise by ID.
func (s *Store) GetExercise(id int64) (Exercise, error) {
	var e Exercise
	var pub int
	err := s.db.QueryRow(
		`SELECT id, topic_id, word, sort_order, pass_confidence, published FROM learn_exercises WHERE id = ?`,
		id).Scan(&e.ID, &e.TopicID, &e.Word, &e.SortOrder, &e.PassConfidence, &pub)
	if errors.Is(err, sql.ErrNoRows) {
		return Exercise{}, ErrNotFound
	}
	if err != nil {
		return Exercise{}, fmt.Errorf("getting exercise: %w", err)
	}
	e.Published = pub != 0
	return e, nil
}

// CreateExercise inserts an exercise and returns it with its assigned ID.
// The referenced topic must exist.
func (s *Store) CreateExercise(e Exercise) (Exercise, error) {
	e.Word = NormalizeWord(e.Word)
	var one int
	err := s.db.QueryRow(`SELECT 1 FROM learn_topics WHERE id = ?`, e.TopicID).Scan(&one)
	if errors.Is(err, sql.ErrNoRows) {
		return Exercise{}, ErrNotFound
	}
	if err != nil {
		return Exercise{}, fmt.Errorf("checking topic: %w", err)
	}
	res, err := s.db.Exec(
		`INSERT INTO learn_exercises (topic_id, word, sort_order, pass_confidence, published) VALUES (?, ?, ?, ?, ?)`,
		e.TopicID, e.Word, e.SortOrder, e.PassConfidence, boolInt(e.Published))
	if err != nil {
		return Exercise{}, fmt.Errorf("creating exercise: %w", err)
	}
	e.ID, _ = res.LastInsertId()
	return e, nil
}

// UpdateExercise overwrites the editable fields of an existing exercise.
func (s *Store) UpdateExercise(e Exercise) error {
	e.Word = NormalizeWord(e.Word)
	res, err := s.db.Exec(
		`UPDATE learn_exercises SET topic_id = ?, word = ?, sort_order = ?, pass_confidence = ?, published = ? WHERE id = ?`,
		e.TopicID, e.Word, e.SortOrder, e.PassConfidence, boolInt(e.Published), e.ID)
	if err != nil {
		return fmt.Errorf("updating exercise: %w", err)
	}
	return checkFound(res)
}

// DeleteExercise removes an exercise and any progress on it.
func (s *Store) DeleteExercise(id int64) error {
	if _, err := s.db.Exec(`DELETE FROM learn_progress WHERE exercise_id = ?`, id); err != nil {
		return fmt.Errorf("deleting exercise progress: %w", err)
	}
	res, err := s.db.Exec(`DELETE FROM learn_exercises WHERE id = ?`, id)
	if err != nil {
		return fmt.Errorf("deleting exercise: %w", err)
	}
	return checkFound(res)
}

// ---- dictionary ----

// ListSigns returns all dictionary entries ordered by category then word,
// without keypoint frames (fetch one sign for the animation payload).
func (s *Store) ListSigns() ([]Sign, error) {
	rows, err := s.db.Query(`
SELECT s.word, s.category, COALESCE(n.note, ''), s.keypoint_frames IS NOT NULL
FROM learn_signs s
LEFT JOIN learn_sign_notes n ON n.word = s.word
ORDER BY s.category, s.word`)
	if err != nil {
		return nil, fmt.Errorf("listing signs: %w", err)
	}
	defer rows.Close()
	signs := []Sign{}
	for rows.Next() {
		var sg Sign
		var has int
		if err := rows.Scan(&sg.Word, &sg.Category, &sg.Note, &has); err != nil {
			return nil, fmt.Errorf("scanning sign: %w", err)
		}
		sg.HasAnimation = has != 0
		signs = append(signs, sg)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing signs: %w", err)
	}
	return signs, nil
}

// NormalizeWord trims whitespace and normalizes common Thai typo patterns:
// - Replaces double sara E ("\u0e40\u0e40") with sara Ae ("\u0e41")
// - Strips unwanted phinthu diacritics ("\u0e3a")
func NormalizeWord(w string) string {
	w = strings.TrimSpace(w)
	w = strings.ReplaceAll(w, "\u0e40\u0e40", "\u0e41")
	w = strings.ReplaceAll(w, "\u0e3a", "")
	return w
}

// GetSign returns one dictionary entry including its keypoint frames.
func (s *Store) GetSign(word string) (Sign, error) {
	word = NormalizeWord(word)
	var sg Sign
	var frames sql.NullString
	err := s.db.QueryRow(`
SELECT s.word, s.category, COALESCE(n.note, ''), s.keypoint_frames
FROM learn_signs s
LEFT JOIN learn_sign_notes n ON n.word = s.word
WHERE s.word = ?`, word).
		Scan(&sg.Word, &sg.Category, &sg.Note, &frames)
	if errors.Is(err, sql.ErrNoRows) {
		return Sign{}, ErrNotFound
	}
	if err != nil {
		return Sign{}, fmt.Errorf("getting sign: %w", err)
	}
	if frames.Valid {
		sg.KeypointFrames = json.RawMessage(frames.String)
		sg.HasAnimation = true
	}
	return sg, nil
}

// UpsertSign creates or updates a dictionary entry's word + category, leaving
// any existing keypoint_frames untouched (the admin sign editor flow).
func (s *Store) UpsertSign(word, category string) error {
	word = NormalizeWord(word)
	_, err := s.db.Exec(`
INSERT INTO learn_signs (word, category) VALUES (?, ?)
ON CONFLICT (word) DO UPDATE SET category = excluded.category`,
		word, category)
	if err != nil {
		return fmt.Errorf("upserting sign: %w", err)
	}
	return nil
}

// SetSignNote stores the admin-written note shown on the example step. The
// dictionary row must already exist; a missing word yields ErrNotFound. An
// empty note clears the row rather than storing a blank string.
func (s *Store) SetSignNote(word, note string) error {
	word = NormalizeWord(word)
	note = strings.TrimSpace(note)
	var exists int
	err := s.db.QueryRow(`SELECT 1 FROM learn_signs WHERE word = ?`, word).Scan(&exists)
	if errors.Is(err, sql.ErrNoRows) {
		return ErrNotFound
	}
	if err != nil {
		return fmt.Errorf("checking sign: %w", err)
	}
	if note == "" {
		if _, err := s.db.Exec(`DELETE FROM learn_sign_notes WHERE word = ?`, word); err != nil {
			return fmt.Errorf("clearing sign note: %w", err)
		}
		return nil
	}
	_, err = s.db.Exec(`
INSERT INTO learn_sign_notes (word, note) VALUES (?, ?)
ON CONFLICT (word) DO UPDATE SET note = excluded.note`, word, note)
	if err != nil {
		return fmt.Errorf("setting sign note: %w", err)
	}
	return nil
}

// SetKeypointFrames stores the avatar animation JSON for an existing sign
// (extracted from a recorded clip). The row must already exist — create it
// with UpsertSign first; a missing word yields ErrNotFound.
func (s *Store) SetKeypointFrames(word string, frames json.RawMessage) error {
	word = NormalizeWord(word)
	res, err := s.db.Exec(
		`UPDATE learn_signs SET keypoint_frames = ? WHERE word = ?`,
		string(frames), word)
	if err != nil {
		return fmt.Errorf("setting keypoint frames: %w", err)
	}
	return checkFound(res)
}

// DeleteSign removes a dictionary entry.
func (s *Store) DeleteSign(word string) error {
	word = NormalizeWord(word)
	res, err := s.db.Exec(`DELETE FROM learn_signs WHERE word = ?`, word)
	if err != nil {
		return fmt.Errorf("deleting sign: %w", err)
	}
	if _, err := s.db.Exec(`DELETE FROM learn_sign_notes WHERE word = ?`, word); err != nil {
		return fmt.Errorf("deleting sign note: %w", err)
	}
	return checkFound(res)
}

// ---- progress ----

// progressSelect joins the never-regressing best result with the attempt
// tallies. It takes the user id twice: once for the attempt sub-select, once
// for the caller's own WHERE clause.
const progressSelect = `
SELECT p.exercise_id, p.best_confidence, p.passed, p.updated_ms,
       COALESCE(a.attempts, 0), COALESCE(a.correct, 0)
FROM learn_progress p
LEFT JOIN (
	SELECT exercise_id, COUNT(*) AS attempts, SUM(passed) AS correct
	FROM learn_attempts WHERE user_id = ? GROUP BY exercise_id
) a ON a.exercise_id = p.exercise_id`

// ListProgress returns the user's progress rows.
func (s *Store) ListProgress(userID int64) ([]Progress, error) {
	rows, err := s.db.Query(progressSelect+` WHERE p.user_id = ?`, userID, userID)
	if err != nil {
		return nil, fmt.Errorf("listing progress: %w", err)
	}
	defer rows.Close()
	out := []Progress{}
	for rows.Next() {
		var p Progress
		var passed int
		if err := rows.Scan(&p.ExerciseID, &p.BestConfidence, &passed, &p.UpdatedMS,
			&p.Attempts, &p.CorrectAttempts); err != nil {
			return nil, fmt.Errorf("scanning progress: %w", err)
		}
		p.Passed = passed != 0
		out = append(out, p)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing progress: %w", err)
	}
	return out, nil
}

// RecordAttempt upserts the user's best confidence for an exercise and
// derives passed from the exercise's own threshold (server-side, so an
// admin threshold edit applies to future attempts). Best confidence and
// passed never regress. Returns the resulting row.
func (s *Store) RecordAttempt(userID, exerciseID int64, confidence float64) (Progress, error) {
	ex, err := s.GetExercise(exerciseID)
	if err != nil {
		return Progress{}, err
	}
	now := time.Now().UnixMilli()
	passed := confidence >= ex.PassConfidence
	// The append-only attempt row is what the "N correct out of M" summary and
	// the admin analytics count; the progress upsert below only tracks the best.
	_, err = s.db.Exec(`
INSERT INTO learn_attempts (user_id, exercise_id, confidence, passed, created_ms)
VALUES (?, ?, ?, ?, ?)`,
		userID, exerciseID, confidence, boolInt(passed), now)
	if err != nil {
		return Progress{}, fmt.Errorf("logging attempt: %w", err)
	}
	_, err = s.db.Exec(`
INSERT INTO learn_progress (user_id, exercise_id, best_confidence, passed, updated_ms)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT (user_id, exercise_id) DO UPDATE SET
	best_confidence = MAX(best_confidence, excluded.best_confidence),
	passed          = MAX(passed, excluded.passed),
	updated_ms      = excluded.updated_ms`,
		userID, exerciseID, confidence, boolInt(passed), now)
	if err != nil {
		return Progress{}, fmt.Errorf("recording attempt: %w", err)
	}
	var p Progress
	var passedInt int
	err = s.db.QueryRow(progressSelect+` WHERE p.user_id = ? AND p.exercise_id = ?`,
		userID, userID, exerciseID).
		Scan(&p.ExerciseID, &p.BestConfidence, &passedInt, &p.UpdatedMS,
			&p.Attempts, &p.CorrectAttempts)
	if err != nil {
		return Progress{}, fmt.Errorf("reading back progress: %w", err)
	}
	p.Passed = passedInt != 0
	return p, nil
}

// ListExerciseStats returns the admin analytics rollup: one row per exercise
// that has at least one logged attempt, newest content first by topic order.
func (s *Store) ListExerciseStats() ([]ExerciseStats, error) {
	rows, err := s.db.Query(`
SELECT e.id, e.word, t.title,
       COUNT(a.id),
       COALESCE(SUM(a.passed), 0),
       COUNT(DISTINCT a.user_id),
       COALESCE(AVG(a.confidence), 0),
       (SELECT COUNT(*) FROM learn_progress p WHERE p.exercise_id = e.id AND p.passed = 1)
FROM learn_exercises e
JOIN learn_topics t ON t.id = e.topic_id
LEFT JOIN learn_attempts a ON a.exercise_id = e.id
GROUP BY e.id
ORDER BY t.sort_order, e.sort_order, e.id`)
	if err != nil {
		return nil, fmt.Errorf("listing exercise stats: %w", err)
	}
	defer rows.Close()
	out := []ExerciseStats{}
	for rows.Next() {
		var st ExerciseStats
		if err := rows.Scan(&st.ExerciseID, &st.Word, &st.TopicTitle,
			&st.Attempts, &st.CorrectAttempts, &st.Learners,
			&st.AvgConfidence, &st.LearnersPassed); err != nil {
			return nil, fmt.Errorf("scanning exercise stats: %w", err)
		}
		out = append(out, st)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("listing exercise stats: %w", err)
	}
	return out, nil
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

// checkFound converts a zero-row UPDATE/DELETE into ErrNotFound.
func checkFound(res sql.Result) error {
	n, err := res.RowsAffected()
	if err != nil {
		return fmt.Errorf("rows affected: %w", err)
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
