package learn

import (
	"encoding/json"
	"errors"
	"log"
	"net/http"
	"strconv"
	"strings"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/auth"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/httpapi"
)

// Handler serves the Learning tab REST API.
//
// App endpoints (any authenticated role):
//
//	GET  /api/v1/learn/topics            published topics with exercises
//	GET  /api/v1/learn/dictionary        all dictionary entries (no frames)
//	GET  /api/v1/learn/dictionary/{word} one entry incl. keypoint frames
//	GET  /api/v1/learn/progress          caller's progress rows
//	POST /api/v1/learn/progress          record an attempt {exercise_id, confidence}
//
// Admin endpoints (admin role):
//
//	GET    /api/v1/admin/learn/topics         all topics incl. unpublished
//	POST   /api/v1/admin/learn/topics         create topic
//	PUT    /api/v1/admin/learn/topics/{id}    update topic
//	DELETE /api/v1/admin/learn/topics/{id}    delete topic (+exercises)
//	POST   /api/v1/admin/learn/exercises      create exercise
//	PUT    /api/v1/admin/learn/exercises/{id} update exercise (incl. pass_confidence)
//	DELETE /api/v1/admin/learn/exercises/{id} delete exercise
type Handler struct {
	store *Store
}

// NewHandler builds the learn API handler over the given store.
func NewHandler(store *Store) *Handler {
	return &Handler{store: store}
}

// RegisterProtected wires the app routes behind userMW (any authenticated
// user) and the admin routes behind adminMW (admin role), matching the
// middleware stacking used in cmd/server/main.go.
func (h *Handler) RegisterProtected(mux *http.ServeMux, userMW, adminMW func(http.Handler) http.Handler) {
	user := func(fn http.HandlerFunc) http.Handler { return userMW(fn) }
	admin := func(fn http.HandlerFunc) http.Handler { return adminMW(fn) }

	mux.Handle("GET /api/v1/learn/topics", user(h.topics))
	mux.Handle("GET /api/v1/learn/dictionary", user(h.dictionary))
	mux.Handle("GET /api/v1/learn/dictionary/{word}", user(h.dictionaryEntry))
	mux.Handle("GET /api/v1/learn/progress", user(h.progress))
	mux.Handle("POST /api/v1/learn/progress", user(h.recordAttempt))

	mux.Handle("GET /api/v1/admin/learn/topics", admin(h.adminTopics))
	mux.Handle("POST /api/v1/admin/learn/topics", admin(h.createTopic))
	mux.Handle("PUT /api/v1/admin/learn/topics/{id}", admin(h.updateTopic))
	mux.Handle("DELETE /api/v1/admin/learn/topics/{id}", admin(h.deleteTopic))
	mux.Handle("POST /api/v1/admin/learn/exercises", admin(h.createExercise))
	mux.Handle("PUT /api/v1/admin/learn/exercises/{id}", admin(h.updateExercise))
	mux.Handle("DELETE /api/v1/admin/learn/exercises/{id}", admin(h.deleteExercise))
}

// ---- app endpoints ----

func (h *Handler) topics(w http.ResponseWriter, r *http.Request) {
	topics, err := h.store.ListTopics(true)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, map[string]any{"topics": topics})
}

func (h *Handler) dictionary(w http.ResponseWriter, r *http.Request) {
	signs, err := h.store.ListSigns()
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, map[string]any{"signs": signs})
}

func (h *Handler) dictionaryEntry(w http.ResponseWriter, r *http.Request) {
	word := strings.TrimSpace(r.PathValue("word"))
	sign, err := h.store.GetSign(word)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, sign)
}

func (h *Handler) progress(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnauthorized, "Authentication required", ""))
		return
	}
	rows, err := h.store.ListProgress(claims.Sub)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, map[string]any{"progress": rows})
}

func (h *Handler) recordAttempt(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnauthorized, "Authentication required", ""))
		return
	}
	var body struct {
		ExerciseID int64   `json:"exercise_id"`
		Confidence float64 `json:"confidence"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed attempt body", err.Error()))
		return
	}
	if body.Confidence < 0 || body.Confidence > 1 {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid confidence", "confidence must be within [0, 1]"))
		return
	}
	p, err := h.store.RecordAttempt(claims.Sub, body.ExerciseID, body.Confidence)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, p)
}

// ---- admin endpoints ----

func (h *Handler) adminTopics(w http.ResponseWriter, r *http.Request) {
	topics, err := h.store.ListTopics(false)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, map[string]any{"topics": topics})
}

func (h *Handler) createTopic(w http.ResponseWriter, r *http.Request) {
	t, ok := decodeTopic(w, r)
	if !ok {
		return
	}
	created, err := h.store.CreateTopic(t)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, created)
}

func (h *Handler) updateTopic(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	t, ok := decodeTopic(w, r)
	if !ok {
		return
	}
	t.ID = id
	if err := h.store.UpdateTopic(t); err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, t)
}

func (h *Handler) deleteTopic(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	if err := h.store.DeleteTopic(id); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) createExercise(w http.ResponseWriter, r *http.Request) {
	e, ok := decodeExercise(w, r)
	if !ok {
		return
	}
	created, err := h.store.CreateExercise(e)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, created)
}

func (h *Handler) updateExercise(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	e, ok := decodeExercise(w, r)
	if !ok {
		return
	}
	e.ID = id
	if err := h.store.UpdateExercise(e); err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, e)
}

func (h *Handler) deleteExercise(w http.ResponseWriter, r *http.Request) {
	id, ok := pathID(w, r)
	if !ok {
		return
	}
	if err := h.store.DeleteExercise(id); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- helpers ----

func decodeTopic(w http.ResponseWriter, r *http.Request) (Topic, bool) {
	var t Topic
	if err := json.NewDecoder(r.Body).Decode(&t); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed topic body", err.Error()))
		return Topic{}, false
	}
	t.Slug = strings.TrimSpace(t.Slug)
	t.Title = strings.TrimSpace(t.Title)
	if t.Slug == "" || t.Title == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid topic", "slug and title are required"))
		return Topic{}, false
	}
	return t, true
}

func decodeExercise(w http.ResponseWriter, r *http.Request) (Exercise, bool) {
	var e Exercise
	if err := json.NewDecoder(r.Body).Decode(&e); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed exercise body", err.Error()))
		return Exercise{}, false
	}
	e.Word = strings.TrimSpace(e.Word)
	if e.Word == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid exercise", "word is required"))
		return Exercise{}, false
	}
	if e.PassConfidence < 0 || e.PassConfidence > 1 {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid exercise",
			"pass_confidence must be within [0, 1]"))
		return Exercise{}, false
	}
	return e, true
}

// pathID parses the {id} path segment; writes a 400 problem on failure.
func pathID(w http.ResponseWriter, r *http.Request) (int64, bool) {
	id, err := strconv.ParseInt(r.PathValue("id"), 10, 64)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid id", err.Error()))
		return 0, false
	}
	return id, true
}

// writeStoreError maps store errors to RFC 7807 responses.
func writeStoreError(w http.ResponseWriter, err error) {
	if errors.Is(err, ErrNotFound) {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusNotFound, "Not found", err.Error()))
		return
	}
	if strings.Contains(err.Error(), "UNIQUE constraint") {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusConflict, "Duplicate", err.Error()))
		return
	}
	httpapi.WriteProblem(w, httpapi.NewProblem(
		http.StatusInternalServerError, "Learn store error", err.Error()))
}

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("learn: writing response: %v", err)
	}
}
