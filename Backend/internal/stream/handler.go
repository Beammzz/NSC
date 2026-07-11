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

	"github.com/gorilla/websocket"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/httpapi"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

type Handler struct {
	ai       AIClient
	upgrader websocket.Upgrader
}

func NewHandler(ai AIClient) *Handler {
	return &Handler{
		ai: ai,
		upgrader: websocket.Upgrader{
			ReadBufferSize:  8192,
			WriteBufferSize: 8192,
			// Mobile app clients send no browser Origin header; browser
			// origins are not part of the product surface.
			CheckOrigin: func(r *http.Request) bool { return true },
		},
	}
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithCancel(r.Context())
	defer cancel()

	aiStream, err := h.ai.OpenStream(ctx)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusServiceUnavailable, "AI service unavailable", err.Error()))
		return
	}

	conn, err := h.upgrader.Upgrade(w, r, nil)
	if err != nil {
		// Upgrade already wrote an HTTP error response.
		return
	}
	defer conn.Close()

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

	// Prediction pump: AI stream -> client.
	go func() {
		for {
			pred, err := aiStream.Recv()
			if err != nil {
				if ctx.Err() == nil {
					send(newErrorMessage(httpapi.NewProblem(
						http.StatusBadGateway, "AI stream closed", err.Error())))
				}
				cancel()
				return
			}
			if !send(newPredictionMessage(pred)) {
				return
			}
		}
	}()

	send(newReadyMessage())
	h.readLoop(ctx, conn, aiStream, send)

	cancel()
	<-writerDone
	if err := aiStream.CloseSend(); err != nil {
		log.Printf("stream: closing AI stream: %v", err)
	}
}

// readLoop forwards client frames to the AI stream until the connection
// closes, the context is cancelled, or a fatal protocol error occurs.
func (h *Handler) readLoop(ctx context.Context, conn *websocket.Conn, aiStream AIStream, send func(any) bool) {
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
				send(newErrorMessage(httpapi.NewProblem(
					http.StatusBadGateway, "AI service error", err.Error())))
				return
			}
		case typeReset:
			if err := aiStream.Send(&pb.LandmarkFrame{Reset_: true}); err != nil {
				send(newErrorMessage(httpapi.NewProblem(
					http.StatusBadGateway, "AI service error", err.Error())))
				return
			}
		default:
			// Unknown types are rejected, not ignored (schema rule).
			send(newErrorMessage(httpapi.NewProblem(
				http.StatusBadRequest, "Unknown message type", msg.Type)))
		}
	}
}
