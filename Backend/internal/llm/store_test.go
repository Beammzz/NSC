package llm

import (
	"path/filepath"
	"testing"
)

func openTemp(t *testing.T) *Store {
	t.Helper()
	store, err := Open(filepath.Join(t.TempDir(), "data", "llm.db"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	t.Cleanup(func() { store.Close() })
	return store
}

func TestGetSettingsReturnsDefaultsWhenNothingSaved(t *testing.T) {
	store := openTemp(t)
	got, err := store.GetSettings()
	if err != nil {
		t.Fatalf("GetSettings: %v", err)
	}
	if got.Endpoint != DefaultEndpoint {
		t.Errorf("Endpoint = %q, want %q", got.Endpoint, DefaultEndpoint)
	}
	if got.Model != DefaultModel {
		t.Errorf("Model = %q, want %q", got.Model, DefaultModel)
	}
	if got.SystemPrompt != DefaultSystemPrompt {
		t.Errorf("SystemPrompt = %q, want the default prompt", got.SystemPrompt)
	}
	if got.SilenceMS != DefaultSilenceMS {
		t.Errorf("SilenceMS = %d, want %d", got.SilenceMS, DefaultSilenceMS)
	}
	if got.Enabled {
		t.Error("Enabled = true, want false before an admin configures a key")
	}
}

func TestSaveSettingsPatchesOnlyProvidedFields(t *testing.T) {
	store := openTemp(t)
	key := "sk-test-123"
	enabled := true
	if _, err := store.SaveSettings(SettingsPatch{APIKey: &key, Enabled: &enabled}); err != nil {
		t.Fatalf("SaveSettings: %v", err)
	}

	prompt := "custom prompt"
	got, err := store.SaveSettings(SettingsPatch{SystemPrompt: &prompt})
	if err != nil {
		t.Fatalf("SaveSettings: %v", err)
	}
	if got.APIKey != key {
		t.Errorf("APIKey = %q, want the earlier %q (nil patch field must not clear it)", got.APIKey, key)
	}
	if !got.Enabled {
		t.Error("Enabled = false, want the earlier true")
	}
	if got.SystemPrompt != prompt {
		t.Errorf("SystemPrompt = %q, want %q", got.SystemPrompt, prompt)
	}
}

func TestSaveSettingsClearsAPIKeyWithEmptyString(t *testing.T) {
	store := openTemp(t)
	key := "sk-test-123"
	if _, err := store.SaveSettings(SettingsPatch{APIKey: &key}); err != nil {
		t.Fatalf("SaveSettings: %v", err)
	}
	empty := ""
	got, err := store.SaveSettings(SettingsPatch{APIKey: &empty})
	if err != nil {
		t.Fatalf("SaveSettings: %v", err)
	}
	if got.APIKey != "" {
		t.Errorf("APIKey = %q, want it cleared", got.APIKey)
	}
}

func TestSaveSettingsClampsOutOfRangeValues(t *testing.T) {
	store := openTemp(t)
	silence := 0
	maxWords := 500
	temperature := 9.0
	got, err := store.SaveSettings(SettingsPatch{
		SilenceMS:   &silence,
		MaxWords:    &maxWords,
		Temperature: &temperature,
	})
	if err != nil {
		t.Fatalf("SaveSettings: %v", err)
	}
	if got.SilenceMS != 200 {
		t.Errorf("SilenceMS = %d, want the 200 floor", got.SilenceMS)
	}
	if got.MaxWords != 64 {
		t.Errorf("MaxWords = %d, want the 64 ceiling", got.MaxWords)
	}
	if got.Temperature != 2 {
		t.Errorf("Temperature = %v, want the 2 ceiling", got.Temperature)
	}
}

func TestInsertAndListLogsRoundtrip(t *testing.T) {
	store := openTemp(t)
	rec := LogRecord{
		CreatedMS: 1_700_000_000_000,
		Words:     []string{"ฉัน", "รัก", "เธอ"},
		Sentence:  "ฉันรักเธอ",
		Raw:       "ฉันรักเธอ",
		Model:     DefaultModel,
		LatencyMS: 412,
		OK:        true,
	}
	if err := store.InsertLog(rec); err != nil {
		t.Fatalf("InsertLog: %v", err)
	}
	got, err := store.ListLogs(QueryOptions{})
	if err != nil {
		t.Fatalf("ListLogs: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("ListLogs returned %d records, want 1", len(got))
	}
	if got[0].Sentence != rec.Sentence {
		t.Errorf("Sentence = %q, want %q", got[0].Sentence, rec.Sentence)
	}
	if len(got[0].Words) != 3 || got[0].Words[0] != "ฉัน" {
		t.Errorf("Words = %v, want %v", got[0].Words, rec.Words)
	}
	if got[0].LatencyMS != 412 {
		t.Errorf("LatencyMS = %d, want 412", got[0].LatencyMS)
	}

	total, err := store.CountLogs()
	if err != nil {
		t.Fatalf("CountLogs: %v", err)
	}
	if total != 1 {
		t.Errorf("CountLogs = %d, want 1", total)
	}

	if err := store.ClearLogs(); err != nil {
		t.Fatalf("ClearLogs: %v", err)
	}
	total, err = store.CountLogs()
	if err != nil {
		t.Fatalf("CountLogs: %v", err)
	}
	if total != 0 {
		t.Errorf("CountLogs after ClearLogs = %d, want 0", total)
	}
}

func TestAutoCleanPrunesOldestLogs(t *testing.T) {
	store := openTemp(t)
	limit := int64(2)
	if _, err := store.SaveSettings(SettingsPatch{AutoCleanMaxLogs: &limit}); err != nil {
		t.Fatalf("SaveSettings: %v", err)
	}
	for _, sentence := range []string{"หนึ่ง", "สอง", "สาม", "สี่"} {
		if err := store.InsertLog(LogRecord{Words: []string{sentence}, Sentence: sentence}); err != nil {
			t.Fatalf("InsertLog: %v", err)
		}
	}
	total, err := store.CountLogs()
	if err != nil {
		t.Fatalf("CountLogs: %v", err)
	}
	if total != 2 {
		t.Fatalf("CountLogs = %d, want 2 after auto-clean", total)
	}
	got, err := store.ListLogs(QueryOptions{})
	if err != nil {
		t.Fatalf("ListLogs: %v", err)
	}
	if got[0].Sentence != "สี่" || got[1].Sentence != "สาม" {
		t.Errorf("retained %q,%q; want the two newest สี่,สาม", got[0].Sentence, got[1].Sentence)
	}
}
