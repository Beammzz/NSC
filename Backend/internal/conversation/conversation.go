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

// Handler returns an http.HandlerFunc that serves POST /api/v1/conversation.
func Handler() http.HandlerFunc {
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

		resp := buildReply(msg)

		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusOK)
		_ = json.NewEncoder(w).Encode(resp)
	}
}

func buildReply(msg string) Response {
	replyText := "สวัสดีค่ะ ยินดีที่ได้พบคุณค่ะ"
	gloss := "สวัสดี พบ ยินดี"

	if strings.Contains(msg, "โรงพยาบาล") {
		replyText = "โรงพยาบาลอยู่ตรงไปทางขวามือค่ะ"
		gloss = "โรงพยาบาล ตรง ขวา"
	} else if strings.Contains(msg, "ขอบคุณ") {
		replyText = "ยินดีเสมอค่ะ มีอะไรให้ช่วยเหลือบอกได้เลยนะคะ"
		gloss = "ยินดี ช่วยเหลือ"
	}

	transitions := [][]LandmarkPoint{
		{
			{X: 0.50, Y: 0.50, Z: 0.0},
			{X: 0.48, Y: 0.45, Z: 0.0},
		},
		{
			{X: 0.52, Y: 0.42, Z: 0.0},
			{X: 0.50, Y: 0.50, Z: 0.0},
		},
	}

	return Response{
		ReplyText:           replyText,
		ReplySignGloss:      gloss,
		KeypointTransitions: transitions,
	}
}
