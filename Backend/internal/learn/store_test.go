package learn

import (
	"database/sql"
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
	if wantSigns != 150 {
		t.Errorf("dictionary seed covers %d words, want the 150-word vocabulary", wantSigns)
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

	rows, err := s.ListProgress(user)
	if err != nil {
		t.Fatalf("listing progress: %v", err)
	}
	if len(rows) != 1 {
		t.Fatalf("progress rows = %d, want 1", len(rows))
	}

	if _, err := s.RecordAttempt(user, 9999, 0.9); !errors.Is(err, ErrNotFound) {
		t.Errorf("attempt on missing exercise: err = %v, want ErrNotFound", err)
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
