package predlog

import (
	"path/filepath"
	"testing"
)

func openTemp(t *testing.T) *Store {
	t.Helper()
	store, err := Open(filepath.Join(t.TempDir(), "data", "predictions.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { store.Close() })
	return store
}

func TestInsertAndListRoundtrip(t *testing.T) {
	store := openTemp(t)
	rec := Record{
		CreatedMS:       1_700_000_000_000,
		Seq:             29,
		Word:            "ขอบคุณ",
		Confidence:      0.9,
		IsUncertain:     false,
		InferenceMicros: 4400,
		OtherProb:       0.05,
		Top: []ClassProb{
			{Label: "ขอบคุณ", Prob: 0.9},
			{Label: "สวัสดี", Prob: 0.05},
		},
	}
	if err := store.Insert(rec); err != nil {
		t.Fatalf("Insert: %v", err)
	}
	got, err := store.List(QueryOptions{})
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 record, got %d", len(got))
	}
	r := got[0]
	if r.Word != "ขอบคุณ" || r.Confidence != 0.9 || r.OtherProb != 0.05 {
		t.Fatalf("roundtrip mismatch: %+v", r)
	}
	if len(r.Top) != 2 || r.Top[1].Label != "สวัสดี" {
		t.Fatalf("top list mismatch: %+v", r.Top)
	}
	if r.ID == 0 || r.CreatedMS != rec.CreatedMS || r.Seq != 29 {
		t.Fatalf("metadata mismatch: %+v", r)
	}
}

func TestEmptyTopStoredAsEmptyList(t *testing.T) {
	store := openTemp(t)
	if err := store.Insert(Record{Word: "", IsIdle: true}); err != nil {
		t.Fatalf("Insert: %v", err)
	}
	got, err := store.List(QueryOptions{})
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if got[0].Top == nil || len(got[0].Top) != 0 {
		t.Fatalf("expected empty (non-nil) top, got %#v", got[0].Top)
	}
	if got[0].CreatedMS == 0 {
		t.Fatal("zero CreatedMS must be stamped on insert")
	}
	if !got[0].IsIdle {
		t.Fatal("is_idle lost in roundtrip")
	}
}

func TestListFiltersAndPagination(t *testing.T) {
	store := openTemp(t)
	words := []string{"a", "b", "a", "c", "a"}
	for i, w := range words {
		err := store.Insert(Record{CreatedMS: int64(1000 + i), Seq: uint64(i), Word: w})
		if err != nil {
			t.Fatalf("Insert %d: %v", i, err)
		}
	}

	byWord, err := store.List(QueryOptions{Word: "a"})
	if err != nil {
		t.Fatalf("List word: %v", err)
	}
	if len(byWord) != 3 {
		t.Fatalf("expected 3 'a' records, got %d", len(byWord))
	}

	since, err := store.List(QueryOptions{SinceMS: 1003})
	if err != nil {
		t.Fatalf("List since: %v", err)
	}
	if len(since) != 2 {
		t.Fatalf("expected 2 records since 1003, got %d", len(since))
	}

	page, err := store.List(QueryOptions{Limit: 2, Offset: 1})
	if err != nil {
		t.Fatalf("List page: %v", err)
	}
	if len(page) != 2 || page[0].Seq != 3 || page[1].Seq != 2 {
		t.Fatalf("expected newest-first page [seq 3, seq 2], got %+v", page)
	}

	n, err := store.Count()
	if err != nil {
		t.Fatalf("Count: %v", err)
	}
	if n != 5 {
		t.Fatalf("expected count 5, got %d", n)
	}
}
