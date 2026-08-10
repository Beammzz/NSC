package learn

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"

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
//	DELETE /api/v1/learn/progress/topic/{id}  clear the caller's progress for one topic
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
//	GET    /api/v1/admin/learn/signs               all dictionary entries (no frames)
//	POST   /api/v1/admin/learn/signs               upsert a sign (word + category)
//	PUT    /api/v1/admin/learn/signs/{word}/note   set the example-step note
//	POST   /api/v1/admin/learn/signs/{word}/recording  extract keypoints from an uploaded clip
//	POST   /api/v1/admin/learn/signs/import-thsl   import sign from th-sl.com link
//	DELETE /api/v1/admin/learn/signs/{word}        delete a sign
//	GET    /api/v1/admin/learn/analytics           per-exercise attempt/correct rollup
const (
	// Multipart parse memory threshold for a sign recording; larger spools to disk.
	recordingMemoryBytes = 8 << 20
	// Hard cap on a recording upload.
	maxRecordingBytes = 100 << 20
	// Hard cap on an admin-written example note.
	maxNoteBytes = 4000
	// Budget for the whole extraction (upload copy + Python MediaPipe pass).
	recordingTimeout = 90 * time.Second
)

// KeypointExtractor turns an uploaded clip into avatar keypoint-frame JSON.
// Implemented by *keypoint.Extractor; an interface here keeps learn decoupled
// from the extraction runtime and trivially fakeable in tests.
type KeypointExtractor interface {
	Configured() bool
	ExtractReader(ctx context.Context, r io.Reader, ext string) (json.RawMessage, error)
}

type Handler struct {
	store     *Store
	extractor KeypointExtractor
}

// NewHandler builds the learn API handler over the given store. extractor may
// be unconfigured (recording uploads then return 503); it is never nil.
func NewHandler(store *Store, extractor KeypointExtractor) *Handler {
	return &Handler{store: store, extractor: extractor}
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
	mux.Handle("DELETE /api/v1/learn/progress/topic/{id}", user(h.resetTopicProgress))

	mux.Handle("GET /api/v1/admin/learn/topics", admin(h.adminTopics))
	mux.Handle("POST /api/v1/admin/learn/topics", admin(h.createTopic))
	mux.Handle("PUT /api/v1/admin/learn/topics/{id}", admin(h.updateTopic))
	mux.Handle("DELETE /api/v1/admin/learn/topics/{id}", admin(h.deleteTopic))
	mux.Handle("POST /api/v1/admin/learn/exercises", admin(h.createExercise))
	mux.Handle("PUT /api/v1/admin/learn/exercises/{id}", admin(h.updateExercise))
	mux.Handle("DELETE /api/v1/admin/learn/exercises/{id}", admin(h.deleteExercise))

	mux.Handle("GET /api/v1/admin/learn/signs", admin(h.adminSigns))
	mux.Handle("POST /api/v1/admin/learn/signs", admin(h.upsertSign))
	mux.Handle("PUT /api/v1/admin/learn/signs/{word}/note", admin(h.setSignNote))
	mux.Handle("POST /api/v1/admin/learn/signs/{word}/recording", admin(h.uploadSignRecording))
	mux.Handle("GET /api/v1/admin/learn/analytics", admin(h.analytics))
	mux.Handle("POST /api/v1/admin/learn/signs/import-thsl", admin(h.importFromThsl))
	mux.Handle("DELETE /api/v1/admin/learn/signs/{word}", admin(h.deleteSign))
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

// resetTopicProgress clears the CALLER's progress for one topic (the app's
// "practise this lesson again" action). It always scopes the delete to the
// token's own user id, so a topic id from the client can never reach another
// learner's rows. The attempt log survives — see Store.ResetTopicProgress.
func (h *Handler) resetTopicProgress(w http.ResponseWriter, r *http.Request) {
	claims, ok := auth.ClaimsFromContext(r.Context())
	if !ok {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnauthorized, "Authentication required", ""))
		return
	}
	topicID, ok := pathID(w, r)
	if !ok {
		return
	}
	cleared, err := h.store.ResetTopicProgress(claims.Sub, topicID)
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, map[string]any{"topic_id": topicID, "cleared": cleared})
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

// ---- admin dictionary / signs ----

func (h *Handler) adminSigns(w http.ResponseWriter, r *http.Request) {
	signs, err := h.store.ListSigns()
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, map[string]any{"signs": signs})
}

func (h *Handler) upsertSign(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Word     string `json:"word"`
		Category string `json:"category"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed sign body", err.Error()))
		return
	}
	body.Word = strings.TrimSpace(body.Word)
	body.Category = strings.TrimSpace(body.Category)
	if body.Word == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid sign", "word is required"))
		return
	}
	if err := h.store.UpsertSign(body.Word, body.Category); err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, map[string]any{"word": body.Word, "category": body.Category})
}

// setSignNote stores the admin-written note the app shows on the example step
// before practice. An empty note clears it.
func (h *Handler) setSignNote(w http.ResponseWriter, r *http.Request) {
	word := strings.TrimSpace(r.PathValue("word"))
	if word == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid sign", "word is required"))
		return
	}
	var body struct {
		Note string `json:"note"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed note body", err.Error()))
		return
	}
	if len(body.Note) > maxNoteBytes {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Note too long",
			fmt.Sprintf("note must be at most %d bytes", maxNoteBytes)))
		return
	}
	if err := h.store.SetSignNote(word, body.Note); err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, map[string]any{
		"word": NormalizeWord(word),
		"note": strings.TrimSpace(body.Note),
	})
}

// analytics returns the per-exercise attempt/correct rollup across all users.
func (h *Handler) analytics(w http.ResponseWriter, r *http.Request) {
	stats, err := h.store.ListExerciseStats()
	if err != nil {
		writeStoreError(w, err)
		return
	}
	writeJSON(w, map[string]any{"exercises": stats})
}

// uploadSignRecording extracts avatar keypoints from an uploaded clip and
// stores them on the sign. An optional "category" form field upserts the sign
// first, so a recording can create a brand-new dictionary entry in one step.
func (h *Handler) uploadSignRecording(w http.ResponseWriter, r *http.Request) {
	word := strings.TrimSpace(r.PathValue("word"))
	if word == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid sign", "word is required"))
		return
	}
	if !h.extractor.Configured() {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusServiceUnavailable, "Recording unavailable",
			"keypoint extraction is not configured on this server"))
		return
	}

	r.Body = http.MaxBytesReader(w, r.Body, maxRecordingBytes)
	if err := r.ParseMultipartForm(recordingMemoryBytes); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed multipart upload", err.Error()))
		return
	}
	defer r.MultipartForm.RemoveAll()

	// Optional category: create/refresh the sign row before storing frames.
	if category := strings.TrimSpace(r.FormValue("category")); category != "" {
		if err := h.store.UpsertSign(word, category); err != nil {
			writeStoreError(w, err)
			return
		}
	}

	file, header, err := r.FormFile("recording")
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Missing recording",
			`form field "recording" (the video clip) is required`))
		return
	}
	defer file.Close()

	ctx, cancel := context.WithTimeout(r.Context(), recordingTimeout)
	defer cancel()
	frames, err := h.extractor.ExtractReader(ctx, file, filepath.Ext(header.Filename))
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnprocessableEntity, "Keypoint extraction failed", err.Error()))
		return
	}

	if err := h.store.SetKeypointFrames(word, frames); err != nil {
		// ErrNotFound here means the sign row doesn't exist and no category was
		// supplied to create it.
		writeStoreError(w, err)
		return
	}
	writeJSON(w, map[string]any{"word": word, "has_animation": true})
}

func (h *Handler) deleteSign(w http.ResponseWriter, r *http.Request) {
	word := strings.TrimSpace(r.PathValue("word"))
	if word == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid sign", "word is required"))
		return
	}
	if err := h.store.DeleteSign(word); err != nil {
		writeStoreError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

var (
	reThslShortcodeWord = regexp.MustCompile(`(?i)<div class="elementor-shortcode">([^<]+)</div>`)
	reThslOgTitle       = regexp.MustCompile(`(?i)<meta property="og:title" content="([^"]+)"`)
	reThslTitle         = regexp.MustCompile(`(?i)<title>([^<]+)</title>`)

	reThslVideoTag     = regexp.MustCompile(`(?i)<video[^>]*src=["']([^"']+)["']`)
	reThslSourceTag    = regexp.MustCompile(`(?i)<source[^>]*src=["']([^"']+)["']`)
	reThslOgVideo      = regexp.MustCompile(`(?i)<meta property="og:video"[^>]*content=["']([^"']+)["']`)
	reThslOgImageMedia = regexp.MustCompile(`(?i)<meta property="og:image"[^>]*content=["']([^"']+\.(?:mp4|webm|gif))["']`)
)

func extractWordFromThslHTML(html string) string {
	raw := ""
	if m := reThslShortcodeWord.FindStringSubmatch(html); len(m) > 1 {
		raw = m[1]
	} else if m := reThslOgTitle.FindStringSubmatch(html); len(m) > 1 {
		raw = m[1]
	} else if m := reThslTitle.FindStringSubmatch(html); len(m) > 1 {
		raw = m[1]
	}
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}

	// Strip " - ฐานข้อมูลภาษามือไทย..." suffix
	if idx := strings.Index(raw, " - "); idx != -1 {
		raw = raw[:idx]
	}
	// Strip "(ท่ามือที่...)"
	if idx := strings.Index(raw, "("); idx != -1 {
		raw = raw[:idx]
	}
	return strings.TrimSpace(raw)
}

func extractVideoURLFromThslHTML(html, pageURL string) string {
	rawURL := ""
	if m := reThslVideoTag.FindStringSubmatch(html); len(m) > 1 {
		rawURL = m[1]
	} else if m := reThslSourceTag.FindStringSubmatch(html); len(m) > 1 {
		rawURL = m[1]
	} else if m := reThslOgVideo.FindStringSubmatch(html); len(m) > 1 {
		rawURL = m[1]
	} else if m := reThslOgImageMedia.FindStringSubmatch(html); len(m) > 1 {
		rawURL = m[1]
	}
	rawURL = strings.TrimSpace(rawURL)
	if rawURL == "" {
		return ""
	}

	// Normalize double slashes in host/path like https://www.th-sl.com//wp-content/...
	if strings.HasPrefix(rawURL, "https://") {
		rawURL = "https://" + strings.ReplaceAll(rawURL[8:], "//", "/")
	} else if strings.HasPrefix(rawURL, "http://") {
		rawURL = "http://" + strings.ReplaceAll(rawURL[7:], "//", "/")
	} else if strings.HasPrefix(rawURL, "//") {
		rawURL = "https:" + strings.ReplaceAll(rawURL, "//", "/")
	} else if strings.HasPrefix(rawURL, "/") {
		base, err := url.Parse(pageURL)
		if err == nil {
			rawURL = base.Scheme + "://" + base.Host + rawURL
		}
	}
	return rawURL
}

// thslAllowedHosts restricts the admin-supplied page URL to the site this
// import feature exists for. Without this, importFromThsl is an SSRF
// primitive: it fetches any URL an admin submits and echoes response
// content back (word/error text, resolved video_url), which is an oracle
// for probing internal services.
var thslAllowedHosts = map[string]bool{
	"th-sl.com":     true,
	"www.th-sl.com": true,
}

// thslFetchClient additionally blocks DNS names (the page URL's host, and
// any video URL the page HTML points at) that resolve to a private,
// loopback, link-local, or otherwise non-public address — defense in depth
// against DNS rebinding, since the host allow-list alone only checks the
// page URL, not the video URL extracted from its HTML.
var thslFetchClient = &http.Client{
	Transport: &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			host, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			ips, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
			if err != nil {
				return nil, err
			}
			if len(ips) == 0 {
				return nil, fmt.Errorf("no addresses found for %s", host)
			}
			for _, ip := range ips {
				if !isPublicIP(ip) {
					return nil, fmt.Errorf("refusing to dial non-public address %s", ip)
				}
			}
			// Dial the already-validated IP directly — dialing addr again
			// would re-resolve the hostname, reopening the DNS-rebinding gap
			// this check exists to close.
			dialer := &net.Dialer{}
			return dialer.DialContext(ctx, network, net.JoinHostPort(ips[0].String(), port))
		},
	},
}

func isPublicIP(ip net.IP) bool {
	return !(ip.IsPrivate() ||
		ip.IsLoopback() ||
		ip.IsLinkLocalUnicast() ||
		ip.IsLinkLocalMulticast() ||
		ip.IsMulticast() ||
		ip.IsUnspecified())
}

func (h *Handler) importFromThsl(w http.ResponseWriter, r *http.Request) {
	if !h.extractor.Configured() {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusServiceUnavailable, "Recording unavailable",
			"keypoint extraction is not configured on this server"))
		return
	}

	var body struct {
		URL      string `json:"url"`
		Word     string `json:"word"`
		Category string `json:"category"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed import body", err.Error()))
		return
	}

	pageURL := strings.TrimSpace(body.URL)
	if pageURL == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid import URL", "url is required"))
		return
	}
	if !strings.HasPrefix(pageURL, "http://") && !strings.HasPrefix(pageURL, "https://") {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid import URL", "url must start with http:// or https://"))
		return
	}
	if parsed, err := url.Parse(pageURL); err != nil || !thslAllowedHosts[strings.ToLower(parsed.Hostname())] {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid import URL", "url host must be th-sl.com"))
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), recordingTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, "GET", pageURL, nil)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Failed to create request for URL", err.Error()))
		return
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

	resp, err := thslFetchClient.Do(req)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadGateway, "Failed to fetch th-sl page", err.Error()))
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadGateway, "th-sl page returned error status", fmt.Sprintf("HTTP %d", resp.StatusCode)))
		return
	}

	htmlBytes, err := io.ReadAll(io.LimitReader(resp.Body, 5<<20))
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Failed to read th-sl HTML", err.Error()))
		return
	}
	html := string(htmlBytes)

	word := strings.TrimSpace(body.Word)
	if word == "" {
		word = extractWordFromThslHTML(html)
	}
	if word == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Could not extract word from URL", "Please specify the word manually"))
		return
	}

	category := strings.TrimSpace(body.Category)
	if category == "" {
		category = "imported"
	}

	videoURL := extractVideoURLFromThslHTML(html, pageURL)
	if videoURL == "" {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnprocessableEntity, "No sign video found", "Could not find video media on th-sl page"))
		return
	}

	vReq, err := http.NewRequestWithContext(ctx, "GET", videoURL, nil)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Failed to build video request", err.Error()))
		return
	}
	vReq.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")

	vResp, err := thslFetchClient.Do(vReq)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadGateway, "Failed to download sign video", err.Error()))
		return
	}
	defer vResp.Body.Close()

	if vResp.StatusCode != http.StatusOK {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadGateway, "Video URL returned error status", fmt.Sprintf("HTTP %d", vResp.StatusCode)))
		return
	}

	ext := filepath.Ext(videoURL)
	if pos := strings.Index(ext, "?"); pos != -1 {
		ext = ext[:pos]
	}
	if ext == "" {
		ext = ".mp4"
	}

	frames, err := h.extractor.ExtractReader(ctx, io.LimitReader(vResp.Body, maxRecordingBytes), ext)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusUnprocessableEntity, "Keypoint extraction failed", err.Error()))
		return
	}

	if err := h.store.UpsertSign(word, category); err != nil {
		writeStoreError(w, err)
		return
	}

	if err := h.store.SetKeypointFrames(word, frames); err != nil {
		writeStoreError(w, err)
		return
	}

	writeJSON(w, map[string]any{
		"word":          word,
		"category":      category,
		"has_animation": true,
		"source_url":    pageURL,
		"video_url":     videoURL,
	})
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
