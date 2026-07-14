// Package conversation provides the REST API handler for /api/v1/conversation.
// It bridges user text or voice transcripts to sign language responses, returning
// both text/gloss and server-rendered keypoint transitions for client avatar animation.
package conversation

import (
	"encoding/json"
	"net/http"
	"strings"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/httpapi"
)

// Request defines the incoming JSON payload for /api/v1/conversation.
type Request struct {
	Message string `json:"message"`
	Locale  string `json:"locale,omitempty"`
}

// LandmarkPoint defines a 3D coordinate for sign avatar keypoints.
type LandmarkPoint struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	Z float64 `json:"z"`
}

// Response defines the outgoing JSON payload with reply text, TSL gloss,
// and keypoint transition frames for avatar rendering.
type Response struct {
	ReplyText           string            `json:"reply_text"`
	ReplySignGloss      string            `json:"reply_sign_gloss"`
	KeypointTransitions [][]LandmarkPoint `json:"keypoint_transitions"`
}

// KeypointLookup returns a gloss word's recorded avatar animation
// (keypoint_frames JSON, shaped [][]LandmarkPoint) and whether one exists. It
// is backed by the learn dictionary store, keeping this package decoupled from
// learn (no import).
type KeypointLookup func(word string) (json.RawMessage, bool)

// Handler returns an http.HandlerFunc that serves POST /api/v1/conversation.
// lookup supplies each reply word's recorded keypoints for avatar stitching; a
// nil lookup yields empty transitions (the client renders the procedural avatar).
func Handler(lookup KeypointLookup) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			httpapi.WriteProblem(w, httpapi.NewProblem(http.StatusMethodNotAllowed, "Method Not Allowed", "POST required for /api/v1/conversation"))
			return
		}

		var req Request
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			httpapi.WriteProblem(w, httpapi.NewProblem(http.StatusBadRequest, "Invalid Request Body", "Payload must be valid JSON containing 'message'"))
			return
		}

		msg := strings.TrimSpace(req.Message)
		if msg == "" {
			httpapi.WriteProblem(w, httpapi.NewProblem(http.StatusBadRequest, "Empty Message", "'message' field cannot be empty"))
			return
		}

		resp := buildReply(msg, lookup)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	}
}

func buildReply(msg string, lookup KeypointLookup) Response {
	replyText := "สวัสดีค่ะ ยินดีที่ได้พบคุณค่ะ"
	gloss := "สวัสดี พบ ยินดี"

	if strings.Contains(msg, "โรงพยาบาล") {
		replyText = "โรงพยาบาลอยู่ตรงไปทางขวามือค่ะ"
		gloss = "โรงพยาบาล ตรง ขวา"
	} else if strings.Contains(msg, "ขอบคุณ") {
		replyText = "ยินดีเสมอค่ะ มีอะไรให้ช่วยเหลือบอกได้เลยนะคะ"
		gloss = "ยินดี ช่วยเหลือ"
	}

	return Response{
		ReplyText:           replyText,
		ReplySignGloss:      gloss,
		KeypointTransitions: stitchGloss(gloss, lookup),
	}
}

// restGapFrames is the brief hold inserted between two stitched signs so the
// words read as distinct rather than blurring into one continuous motion.
const restGapFrames = 3

// stitchGloss builds the reply's avatar sequence by concatenating each gloss
// word's recorded keypoint frames from the shared dictionary library, holding
// the previous sign's final frame for a short gap between words. Words with no
// recorded animation (or a nil lookup) are skipped; when nothing matches the
// result is empty and the client falls back to the procedural avatar.
func stitchGloss(gloss string, lookup KeypointLookup) [][]LandmarkPoint {
	out := [][]LandmarkPoint{}
	if lookup == nil {
		return out
	}
	for _, word := range strings.Fields(gloss) {
		raw, ok := lookup(word)
		if !ok || len(raw) == 0 {
			continue
		}
		var frames [][]LandmarkPoint
		if err := json.Unmarshal(raw, &frames); err != nil || len(frames) == 0 {
			continue
		}
		if len(out) > 0 {
			last := out[len(out)-1]
			for i := 0; i < restGapFrames; i++ {
				out = append(out, last)
			}
		}
		out = append(out, frames...)
	}
	return out
}
