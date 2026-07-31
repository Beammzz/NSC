package learn

import (
	"database/sql"
	"encoding/json"
	"errors"
	"testing"

	_ "modernc.org/sqlite"
)

func testStore(t *testing.T) *Store {
	t.Helper()
	db, err := sql.Open("sqlite", ":memory:?_pragma=journal_mode(WAL)")
	if err != nil {
		t.Fatalf("opening in-memory db: %v", err)
	}
	t.Cleanup(func() { db.Close() })
	s, err := OpenWith(db)
	if err != nil {
		t.Fatalf("opening learn store: %v", err)
	}
	return s
}

func TestSeedIdempotent(t *testing.T) {
	s := testStore(t)
	if err := Seed(s); err != nil {
		t.Fatalf("first seed: %v", err)
	}
	topics, err := s.ListTopics(true)
	if err != nil {
		t.Fatalf("listing topics: %v", err)
	}
	if len(topics) != len(seedTopics) {
		t.Fatalf("seeded %d topics, want %d", len(topics), len(seedTopics))
	}
	for _, topic := range topics {
		if len(topic.Exercises) == 0 {
			t.Errorf("topic %q seeded without exercises", topic.Slug)
		}
		for _, e := range topic.Exercises {
			if e.PassConfidence != defaultPassConfidence {
				t.Errorf("exercise %q pass_confidence = %v, want %v",
					e.Word, e.PassConfidence, defaultPassConfidence)
			}
		}
	}

	signs, err := s.ListSigns()
	if err != nil {
		t.Fatalf("listing signs: %v", err)
	}
	wantSigns := 0
	for _, words := range dictionaryCategories {
		wantSigns += len(words)
	}
	if wantSigns != 220 {
		t.Errorf("dictionary seed covers %d words, want 220 words", wantSigns)
	}
	if len(signs) != wantSigns {
		t.Fatalf("seeded %d signs, want %d", len(signs), wantSigns)
	}

	// Second seed must not duplicate or reset anything.
	if err := s.UpdateTopic(Topic{ID: topics[0].ID, Slug: topics[0].Slug,
		Title: "edited", Icon: topics[0].Icon, SortOrder: 99, Published: false}); err != nil {
		t.Fatalf("editing topic: %v", err)
	}
	if err := Seed(s); err != nil {
		t.Fatalf("second seed: %v", err)
	}
	all, err := s.ListTopics(false)
	if err != nil {
		t.Fatalf("listing all topics: %v", err)
	}
	if len(all) != len(seedTopics) {
		t.Fatalf("after reseed: %d topics, want %d (seed must be idempotent)", len(all), len(seedTopics))
	}
	signs2, _ := s.ListSigns()
	if len(signs2) != wantSigns {
		t.Fatalf("after reseed: %d signs, want %d", len(signs2), wantSigns)
	}
}

func TestTopicExerciseCRUD(t *testing.T) {
	s := testStore(t)
	topic, err := s.CreateTopic(Topic{Slug: "food", Title: "อาหาร", Icon: "🍚", Published: true})
	if err != nil {
		t.Fatalf("creating topic: %v", err)
	}

	ex, err := s.CreateExercise(Exercise{TopicID: topic.ID, Word: "กิน", PassConfidence: 0.8, Published: true})
	if err != nil {
		t.Fatalf("creating exercise: %v", err)
	}

	// Threshold edit (the admin webui flow).
	ex.PassConfidence = 0.9
	if err := s.UpdateExercise(ex); err != nil {
		t.Fatalf("updating exercise: %v", err)
	}
	got, err := s.GetExercise(ex.ID)
	if err != nil {
		t.Fatalf("getting exercise: %v", err)
	}
	if got.PassConfidence != 0.9 {
		t.Errorf("pass_confidence = %v, want 0.9", got.PassConfidence)
	}

	// Unpublished exercises hidden from the app view.
	got.Published = false
	if err := s.UpdateExercise(got); err != nil {
		t.Fatalf("unpublishing exercise: %v", err)
	}
	pub, _ := s.ListTopics(true)
	if len(pub) != 1 || len(pub[0].Exercises) != 0 {
		t.Errorf("published view should hide unpublished exercises, got %+v", pub)
	}

	// Exercise on a missing topic is rejected.
	if _, err := s.CreateExercise(Exercise{TopicID: 9999, Word: "x"}); !errors.Is(err, ErrNotFound) {
		t.Errorf("creating exercise on missing topic: err = %v, want ErrNotFound", err)
	}

	// Deleting the topic cascades.
	if err := s.DeleteTopic(topic.ID); err != nil {
		t.Fatalf("deleting topic: %v", err)
	}
	if _, err := s.GetExercise(ex.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("exercise should be gone after topic delete, err = %v", err)
	}
	if err := s.DeleteTopic(topic.ID); !errors.Is(err, ErrNotFound) {
		t.Errorf("double delete: err = %v, want ErrNotFound", err)
	}
}

func TestRecordAttempt(t *testing.T) {
	s := testStore(t)
	topic, _ := s.CreateTopic(Topic{Slug: "t", Title: "t", Published: true})
	ex, _ := s.CreateExercise(Exercise{TopicID: topic.ID, Word: "กิน", PassConfidence: 0.8, Published: true})

	const user = int64(7)

	p, err := s.RecordAttempt(user, ex.ID, 0.75)
	if err != nil {
		t.Fatalf("recording attempt: %v", err)
	}
	if p.Passed || p.BestConfidence != 0.75 {
		t.Errorf("below-threshold attempt: %+v, want passed=false best=0.75", p)
	}

	p, err = s.RecordAttempt(user, ex.ID, 0.85)
	if err != nil {
		t.Fatalf("recording passing attempt: %v", err)
	}
	if !p.Passed || p.BestConfidence != 0.85 {
		t.Errorf("passing attempt: %+v, want passed=true best=0.85", p)
	}

	// A later weaker attempt never regresses best confidence or passed.
	p, err = s.RecordAttempt(user, ex.ID, 0.5)
	if err != nil {
		t.Fatalf("recording weaker attempt: %v", err)
	}
	if !p.Passed || p.BestConfidence != 0.85 {
		t.Errorf("weaker attempt regressed progress: %+v", p)
	}
	// Every try counts, including the failed ones: 3 attempts, 1 correct.
	if p.Attempts != 3 || p.CorrectAttempts != 1 {
		t.Errorf("attempts = %d/%d correct, want 3/1", p.Attempts, p.CorrectAttempts)
	}

	rows, err := s.ListProgress(user)
	if err != nil {
		t.Fatalf("listing progress: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("progress rows = %d, want 1", len(rows))
	}
	if rows[0].Attempts != 3 || rows[0].CorrectAttempts != 1 {
		t.Errorf("listed attempts = %d/%d correct, want 3/1",
			rows[0].Attempts, rows[0].CorrectAttempts)
	}

	// Another learner's attempts must not leak into this user's tallies.
	if _, err := s.RecordAttempt(8, ex.ID, 0.95); err != nil {
		t.Fatalf("recording other user attempt: %v", err)
	}
	rows, _ = s.ListProgress(user)
	if rows[0].Attempts != 3 {
		t.Errorf("attempts leaked across users: %d, want 3", rows[0].Attempts)
	}

	if _, err := s.RecordAttempt(user, 9999, 0.9); !errors.Is(err, ErrNotFound) {
		t.Errorf("attempt on missing exercise: err = %v, want ErrNotFound", err)
	}
}

func TestSignNote(t *testing.T) {
	s := testStore(t)
	if err := s.UpsertSign("กิน", "กริยา"); err != nil {
		t.Fatalf("upsert: %v", err)
	}

	if err := s.SetSignNote("กิน", "  ยกมือขึ้นที่ปาก  "); err != nil {
		t.Fatalf("set note: %v", err)
	}
	sg, err := s.GetSign("กิน")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if sg.Note != "ยกมือขึ้นที่ปาก" {
		t.Errorf("note = %q, want trimmed ยกมือขึ้นที่ปาก", sg.Note)
	}
	signs, _ := s.ListSigns()
	if len(signs) != 1 || signs[0].Note != "ยกมือขึ้นที่ปาก" {
		t.Errorf("listed note = %+v, want the stored note", signs)
	}

	// The note is a separate row, so a category upsert must not clear it.
	if err := s.UpsertSign("กิน", "การกระทำ"); err != nil {
		t.Fatalf("upsert update: %v", err)
	}
	sg, _ = s.GetSign("กิน")
	if sg.Note != "ยกมือขึ้นที่ปาก" {
		t.Errorf("note lost on category upsert: %+v", sg)
	}

	// Blank clears it; a sign with no note reads as empty, never an error.
	if err := s.SetSignNote("กิน", "   "); err != nil {
		t.Fatalf("clear note: %v", err)
	}
	sg, _ = s.GetSign("กิน")
	if sg.Note != "" {
		t.Errorf("note = %q after clear, want empty", sg.Note)
	}

	if err := s.SetSignNote("ไม่มีคำนี้", "x"); !errors.Is(err, ErrNotFound) {
		t.Errorf("note on missing sign: err = %v, want ErrNotFound", err)
	}

	// Deleting the sign takes its note with it, so a re-created word starts clean.
	if err := s.SetSignNote("กิน", "โน้ต"); err != nil {
		t.Fatalf("re-set note: %v", err)
	}
	if err := s.DeleteSign("กิน"); err != nil {
		t.Fatalf("delete sign: %v", err)
	}
	if err := s.UpsertSign("กิน", "กริยา"); err != nil {
		t.Fatalf("re-create sign: %v", err)
	}
	sg, _ = s.GetSign("กิน")
	if sg.Note != "" {
		t.Errorf("stale note survived delete: %q", sg.Note)
	}
}

func TestResetTopicProgress(t *testing.T) {
	s := testStore(t)
	topic, _ := s.CreateTopic(Topic{Slug: "t", Title: "t", Published: true})
	a, _ := s.CreateExercise(Exercise{TopicID: topic.ID, Word: "กิน", PassConfidence: 0.8, Published: true})
	b, _ := s.CreateExercise(Exercise{TopicID: topic.ID, Word: "ดื่ม", PassConfidence: 0.8, Published: true})
	other, _ := s.CreateTopic(Topic{Slug: "o", Title: "o", Published: true})
	keep, _ := s.CreateExercise(Exercise{TopicID: other.ID, Word: "นอน", PassConfidence: 0.8, Published: true})

	const user = int64(7)
	for _, ex := range []Exercise{a, b, keep} {
		if _, err := s.RecordAttempt(user, ex.ID, 0.9); err != nil {
			t.Fatalf("recording attempt: %v", err)
		}
	}
	// A second learner's rows must survive the first learner's reset.
	if _, err := s.RecordAttempt(8, a.ID, 0.95); err != nil {
		t.Fatalf("recording other-user attempt: %v", err)
	}

	cleared, err := s.ResetTopicProgress(user, topic.ID)
	if err != nil {
		t.Fatalf("resetting: %v", err)
	}
	if cleared != 2 {
		t.Errorf("cleared = %d rows, want 2", cleared)
	}

	rows, _ := s.ListProgress(user)
	if len(rows) != 1 || rows[0].ExerciseID != keep.ID {
		t.Fatalf("after reset the user should keep only the other topic, got %+v", rows)
	}
	if len(mustProgress(t, s, 8)) != 1 {
		t.Errorf("reset leaked into another learner's progress")
	}

	// The attempt log is kept, so admin analytics still sees the old tries and
	// a fresh attempt resumes the tally rather than starting over.
	stats, _ := s.ListExerciseStats()
	for _, st := range stats {
		if st.ExerciseID == a.ID && st.Attempts != 2 {
			t.Errorf("attempt log lost on reset: %+v", st)
		}
	}

	// Resetting a topic that was never practised is a no-op, not an error.
	again, err := s.ResetTopicProgress(user, topic.ID)
	if err != nil || again != 0 {
		t.Errorf("second reset: cleared = %d, err = %v; want 0, nil", again, err)
	}

	// After the reset the exercise is practisable again from zero.
	p, err := s.RecordAttempt(user, a.ID, 0.5)
	if err != nil {
		t.Fatalf("re-practising: %v", err)
	}
	if p.Passed || p.BestConfidence != 0.5 {
		t.Errorf("reset did not clear pass/best: %+v", p)
	}
}

func mustProgress(t *testing.T, s *Store, userID int64) []Progress {
	t.Helper()
	rows, err := s.ListProgress(userID)
	if err != nil {
		t.Fatalf("listing progress for %d: %v", userID, err)
	}
	return rows
}

func TestListExerciseStats(t *testing.T) {
	s := testStore(t)
	topic, _ := s.CreateTopic(Topic{Slug: "t", Title: "ทักทาย", Published: true})
	ex, _ := s.CreateExercise(Exercise{TopicID: topic.ID, Word: "กิน", PassConfidence: 0.8, Published: true})
	untouched, _ := s.CreateExercise(Exercise{TopicID: topic.ID, Word: "ดื่ม", PassConfidence: 0.8, Published: true})

	for _, c := range []float64{0.5, 0.9, 0.95} {
		if _, err := s.RecordAttempt(1, ex.ID, c); err != nil {
			t.Fatalf("recording attempt: %v", err)
		}
	}
	if _, err := s.RecordAttempt(2, ex.ID, 0.4); err != nil {
		t.Fatalf("recording second-user attempt: %v", err)
	}

	stats, err := s.ListExerciseStats()
	if err != nil {
		t.Fatalf("listing stats: %v", err)
	}
	byID := map[int64]ExerciseStats{}
	for _, st := range stats {
		byID[st.ExerciseID] = st
	}
	got := byID[ex.ID]
	if got.Attempts != 4 || got.CorrectAttempts != 2 {
		t.Errorf("stats = %d attempts / %d correct, want 4/2", got.Attempts, got.CorrectAttempts)
	}
	if got.Learners != 2 || got.LearnersPassed != 1 {
		t.Errorf("learners = %d (%d passed), want 2 (1 passed)", got.Learners, got.LearnersPassed)
	}
	if got.TopicTitle != "ทักทาย" || got.Word != "กิน" {
		t.Errorf("stats labels = %+v", got)
	}

	// An exercise nobody has tried still reports, with zeroes.
	zero, ok := byID[untouched.ID]
	if !ok {
		t.Fatalf("untried exercise missing from stats")
	}
	if zero.Attempts != 0 || zero.Learners != 0 || zero.AvgConfidence != 0 {
		t.Errorf("untried exercise stats = %+v, want zeroes", zero)
	}
}

func TestGetSignFrames(t *testing.T) {
	s := testStore(t)
	if err := Seed(s); err != nil {
		t.Fatalf("seeding: %v", err)
	}

	sg, err := s.GetSign("กิน")
	if err != nil {
		t.Fatalf("getting sign: %v", err)
	}
	if sg.HasAnimation || sg.KeypointFrames != nil {
		t.Errorf("seeded sign should have no animation, got %+v", sg)
	}
	if sg.Category == "" {
		t.Errorf("seeded sign missing category")
	}

	if _, err := s.GetSign("ไม่มีคำนี้"); !errors.Is(err, ErrNotFound) {
		t.Errorf("missing sign: err = %v, want ErrNotFound", err)
	}
}

func TestSignWriteMethods(t *testing.T) {
	s := testStore(t)

	// Upsert creates the row; a second upsert updates category but must not
	// wipe frames set in between.
	if err := s.UpsertSign("กิน", "กริยา"); err != nil {
		t.Fatalf("upsert create: %v", err)
	}
	frames := json.RawMessage(`[[{"x":0.5,"y":0.5,"z":0}]]`)
	if err := s.SetKeypointFrames("กิน", frames); err != nil {
		t.Fatalf("set frames: %v", err)
	}
	if err := s.UpsertSign("กิน", "การกระทำ"); err != nil {
		t.Fatalf("upsert update: %v", err)
	}
	sg, err := s.GetSign("กิน")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	if sg.Category != "การกระทำ" {
		t.Errorf("category = %q, want การกระทำ", sg.Category)
	}
	if !sg.HasAnimation || string(sg.KeypointFrames) != string(frames) {
		t.Errorf("frames not preserved across upsert: %+v", sg)
	}

	// Setting frames on a missing sign is a not-found (create it first).
	if err := s.SetKeypointFrames("ไม่มี", frames); !errors.Is(err, ErrNotFound) {
		t.Errorf("set frames on missing sign: err = %v, want ErrNotFound", err)
	}

	// Delete removes it; a second delete is a not-found.
	if err := s.DeleteSign("กิน"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, err := s.GetSign("กิน"); !errors.Is(err, ErrNotFound) {
		t.Errorf("sign should be gone, err = %v", err)
	}
	if err := s.DeleteSign("กิน"); !errors.Is(err, ErrNotFound) {
		t.Errorf("double delete: err = %v, want ErrNotFound", err)
	}
}
