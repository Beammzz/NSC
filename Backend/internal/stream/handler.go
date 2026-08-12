// Package stream implements the /api/v1/stream WebSocket endpoint: it
// accepts landmark frames from the Flutter client (schema:
// docs/api/stream-schema.md) and bridges them to the Python AI service over
// gRPC bidirectional streaming.
package stream

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"
	"google.golang.org/grpc/status"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/auth"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/httpapi"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

// maxClientMessageBytes bounds one inbound WS frame. A legitimate
// landmark_frame is 441 floats plus a small envelope (well under 10 KiB as
// JSON); this leaves generous headroom while stopping an authenticated
// client from OOMing the process with one oversized frame (gorilla/websocket
// buffers a message fully before ReadMessage returns, and has no size limit
// by default).
const maxClientMessageBytes = 64 * 1024

// Per-account and server-wide caps on concurrent /api/v1/stream connections.
// Each connection holds a gRPC stream + 2 goroutines against the AI service;
// signup is public by default (SIGNMIND_ALLOW_SIGNUP), so any account must
// not be able to exhaust that capacity by opening unbounded connections.
const (
	maxStreamsPerUser = 4
	maxStreamsTotal   = 500
)

// aiProblem maps an AI-service error onto an RFC 7807 problem. A genuine
// gRPC status error uses the AI service's own message (safe — it's text the
// service chose to send, e.g. "no model loaded"); anything else (a raw
// transport/dial error) is reduced to a fixed detail so internal network
// topology (addresses, "connection refused", etc.) never reaches the
// client — the real error is still logged server-side.
func aiProblem(httpStatus int, title string, err error) httpapi.Problem {
	if s, ok := status.FromError(err); ok {
		return httpapi.NewProblem(httpStatus, title, s.Message())
	}
	log.Printf("stream: %s: %v", title, err)
	return httpapi.NewProblem(httpStatus, title, "AI service connection error")
}

type Handler struct {
	ai       AIClient
	record   func(*pb.Prediction)
	composer SentenceComposer
	upgrader websocket.Upgrader
	limiter  *connLimiter
}

// NewHandler bridges WS clients to the AI service. record may be nil; when
// set it is invoked for every prediction (the webui's prediction log).
// composer may be nil; when set, the words of each signing burst are composed
// into a sentence at the end of a pause and pushed to the client.
func NewHandler(ai AIClient, record func(*pb.Prediction), composer SentenceComposer) *Handler {
	return &Handler{
		ai:       ai,
		record:   record,
		composer: composer,
		upgrader: websocket.Upgrader{
			ReadBufferSize:  8192,
			WriteBufferSize: 8192,
			// Mobile app clients send no browser Origin header; browser
			// origins are not part of the product surface.
			CheckOrigin: func(r *http.Request) bool { return true },
		},
		limiter: newConnLimiter(maxStreamsPerUser, maxStreamsTotal),
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// requireAuth (wrapping this handler at the route level) guarantees
	// claims are present; the zero value only matters for the connLimiter's
	// bookkeeping key, not for authorization.
	claims, _ := auth.ClaimsFromContext(r.Context())
	if !h.limiter.acquire(claims.Sub) {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusTooManyRequests, "Too many concurrent streams",
			"close an existing scanner connection before opening another"))
		return
	}
	defer h.limiter.release(claims.Sub)

	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	aiStream, err := h.ai.OpenStream(ctx)
	if err != nil {
		httpapi.WriteProblem(w, aiProblem(
			http.StatusServiceUnavailable, "AI service unavailable", err))
		return
	}

	conn, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		// Upgrade already wrote an HTTP error response.
		return
	}
	defer conn.Close()
	conn.SetReadLimit(maxClientMessageBytes)

	// gorilla/websocket allows at most one concurrent writer: everything
	// outbound goes through the out channel and this single writer goroutine.
	out := make(chan any, 16)
	writerDone := make(chan struct{})
	go func() {
		defer close(writerDone)
		for {
			select {
			case msg := <-out:
				if err := conn.WriteJSON(msg); err != nil {
					cancel()
					return
				}
			case <-ctx.Done():
				return
			}
		}
	}()

	send := func(msg any) bool {
		select {
		case out <- msg:
			return true
		case <-ctx.Done():
			return false
		}
	}

	// Sentence buffer: collects recognized words and composes them once the
	// signer pauses (nil when no composer is wired).
	sentences := newSentenceBuffer(ctx, h.composer, send)
	defer sentences.close()

	// Prediction pump: AI stream -> client.
	go func() {
		for {
			pred, err := aiStream.Recv()
			if err != nil {
				if ctx.Err() == nil {
					send(newErrorMessage(aiProblem(
						http.StatusBadGateway, "AI stream closed", err)))
				}
				cancel()
				return
			}
			if h.record != nil {
				h.record(pred)
			}
			sentences.observe(pred)
			if !send(newPredictionMessage(pred)) {
				return
			}
		}
	}()

	send(newReadyMessage())
	h.readLoop(ctx, conn, aiStream, sentences, send)

	cancel()
	<-writerDone
	if err := aiStream.CloseSend(); err != nil {
		log.Printf("stream: closing AI stream: %v", err)
	}
}

// readLoop forwards client frames to the AI stream until the connection
// closes, the context is cancelled, or a fatal protocol error occurs.
func (h *Handler) readLoop(ctx context.Context, conn *websocket.Conn, aiStream AIStream, sentences *sentenceBuffer, send func(any) bool) {
	for {
		if ctx.Err() != nil {
			return
		}
		_, data, err := conn.ReadMessage()
		if err != nil {
			return
		}

		var msg clientMessage
		if err := json.Unmarshal(data, &msg); err != nil {
			send(newErrorMessage(httpapi.NewProblem(
				http.StatusBadRequest, "Malformed message", err.Error())))
			continue
		}
		if msg.SchemaVersion != schemaVersion {
			// Unsupported schema is fatal per docs/api/stream-schema.md.
			send(newErrorMessage(httpapi.NewProblem(
				http.StatusBadRequest, "Unsupported schema_version",
				fmt.Sprintf("supported: %d, got: %d", schemaVersion, msg.SchemaVersion))))
			return
		}

		switch msg.Type {
		case typeLandmarkFrame:
			if len(msg.Features) != featureDim {
				send(newErrorMessage(httpapi.NewProblem(
					http.StatusBadRequest, "Invalid landmark frame",
					fmt.Sprintf("features must contain exactly %d values, got %d",
						featureDim, len(msg.Features)))))
				continue
			}
			frame := &pb.LandmarkFrame{
				Seq:         msg.Seq,
				TimestampMs: msg.TimestampMS,
				Features:    msg.Features,
			}
			if err := aiStream.Send(frame); err != nil {
				send(newErrorMessage(aiProblem(
					http.StatusBadGateway, "AI service error", err)))
				return
			}
		case typeReset:
			sentences.reset()
			if err := aiStream.Send(&pb.LandmarkFrame{Reset_: true}); err != nil {
				send(newErrorMessage(aiProblem(
					http.StatusBadGateway, "AI service error", err)))
				return
			}
		default:
			// Unknown types are rejected, not ignored (schema rule).
			send(newErrorMessage(httpapi.NewProblem(
				http.StatusBadRequest, "Unknown message type", msg.Type)))
		}
	}
}

// connLimiter caps concurrent /api/v1/stream connections per user and
// server-wide.
type connLimiter struct {
	mu         sync.Mutex
	perUser    map[int64]int
	maxPerUser int
	total      int
	maxTotal   int
}

func newConnLimiter(maxPerUser, maxTotal int) *connLimiter {
	return &connLimiter{
		perUser:    make(map[int64]int),
		maxPerUser: maxPerUser,
		maxTotal:   maxTotal,
	}
}

// acquire reports whether a new connection for userID fits under both caps,
// reserving a slot if so.
func (l *connLimiter) acquire(userID int64) bool {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.total >= l.maxTotal || l.perUser[userID] >= l.maxPerUser {
		return false
	}
	l.total++
	l.perUser[userID]++
	return true
}

// release frees the slot reserved by a matching acquire(userID) call.
func (l *connLimiter) release(userID int64) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.total--
	l.perUser[userID]--
	if l.perUser[userID] <= 0 {
		delete(l.perUser, userID)
	}
}
