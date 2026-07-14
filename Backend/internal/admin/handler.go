// Package admin serves the webui management REST API under /api/v1/admin/:
// service status, runtime tuning, the prediction log (SQLite), model upload
// (proxied to the AI service's UploadModel gRPC), and live AI-service logs
// (StreamLogs proxied as Server-Sent Events).
package admin

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"mime/multipart"
	"net/http"
	"strconv"
	"time"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/config"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/httpapi"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/predlog"
)

const (
	rpcTimeout    = 3 * time.Second
	uploadTimeout = 5 * time.Minute
	// Multipart parse memory threshold; larger parts spool to temp files.
	uploadMemoryBytes = 32 << 20
	// Hard cap on a whole upload request (model + label map + config).
	maxUploadBytes = 600 << 20
	uploadChunkLen = 1 << 20 // suggested chunk size per the proto contract

	defaultLogHistory = 200
	maxLogHistory     = 500
)

type Handler struct {
	ai    pb.TslInferenceClient
	store *predlog.Store
	cfg   config.Config
}

func New(ai pb.TslInferenceClient, store *predlog.Store, cfg config.Config) *Handler {
	return &Handler{ai: ai, store: store, cfg: cfg}
}

// Register mounts the admin routes on mux (unprotected — for tests).
func (h *Handler) Register(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/admin/status", h.status)
	mux.HandleFunc("PUT /api/v1/admin/tuning", h.setTuning)
	mux.HandleFunc("GET /api/v1/admin/predictions", h.predictions)
	mux.HandleFunc("DELETE /api/v1/admin/predictions", h.clearPredictions)
	mux.HandleFunc("POST /api/v1/admin/model", h.uploadModel)
	mux.HandleFunc("GET /api/v1/admin/logs", h.logs)
}

// RegisterProtected mounts admin routes wrapped with the provided auth
// middleware chain (RequireAuth + RequireRole("admin") in production).
func (h *Handler) RegisterProtected(mux *http.ServeMux, mw func(http.Handler) http.Handler) {
	mux.Handle("GET /api/v1/admin/status", mw(http.HandlerFunc(h.status)))
	mux.Handle("PUT /api/v1/admin/tuning", mw(http.HandlerFunc(h.setTuning)))
	mux.Handle("GET /api/v1/admin/predictions", mw(http.HandlerFunc(h.predictions)))
	mux.Handle("DELETE /api/v1/admin/predictions", mw(http.HandlerFunc(h.clearPredictions)))
	mux.Handle("POST /api/v1/admin/model", mw(http.HandlerFunc(h.uploadModel)))
	mux.Handle("GET /api/v1/admin/logs", mw(http.HandlerFunc(h.logs)))
}

// ---- status ----

type tuningJSON struct {
	ConfidenceThreshold    float32 `json:"confidence_threshold"`
	IdleMinFramesWithHands uint32  `json:"idle_min_frames_with_hands"`
	IdleMotionStdThreshold float32 `json:"idle_motion_std_threshold"`
	DebugMode              bool    `json:"debug_mode"`
	ModelLoaded            bool    `json:"model_loaded"`
	NumClasses             uint32  `json:"num_classes"`
	SequenceLen            uint32  `json:"sequence_len"`
	FeatureDim             uint32  `json:"feature_dim"`
}

func tuningFromState(s *pb.TuningState) *tuningJSON {
	return &tuningJSON{
		ConfidenceThreshold:    s.GetConfidenceThreshold(),
		IdleMinFramesWithHands: s.GetIdleMinFramesWithHands(),
		IdleMotionStdThreshold: s.GetIdleMotionStdThreshold(),
		DebugMode:              s.GetDebugMode(),
		ModelLoaded:            s.GetModelLoaded(),
		NumClasses:             s.GetNumClasses(),
		SequenceLen:            s.GetSequenceLen(),
		FeatureDim:             s.GetFeatureDim(),
	}
}

func (h *Handler) status(w http.ResponseWriter, r *http.Request) {
	resp := struct {
		Env              string      `json:"env"`
		Debug            bool        `json:"debug"`
		AIOnline         bool        `json:"ai_online"`
		AIError          string      `json:"ai_error,omitempty"`
		Tuning           *tuningJSON `json:"tuning,omitempty"`
		PredictionsTotal int64       `json:"predictions_total"`
	}{Env: h.cfg.Env, Debug: h.cfg.IsDev()}

	ctx, cancel := context.WithTimeout(r.Context(), rpcTimeout)
	defer cancel()
	state, err := h.ai.GetTuning(ctx, &pb.GetTuningRequest{})
	if err != nil {
		resp.AIError = err.Error()
	} else {
		resp.AIOnline = true
		resp.Tuning = tuningFromState(state)
	}

	total, err := h.store.Count()
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Prediction log unavailable", err.Error()))
		return
	}
	resp.PredictionsTotal = total
	writeJSON(w, resp)
}

// ---- tuning ----

func (h *Handler) setTuning(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ConfidenceThreshold    *float32 `json:"confidence_threshold"`
		IdleMinFramesWithHands *uint32  `json:"idle_min_frames_with_hands"`
		IdleMotionStdThreshold *float32 `json:"idle_motion_std_threshold"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed tuning body", err.Error()))
		return
	}
	// debug_mode is deliberately not settable here: it follows ENV in
	// Backend/.env (see SyncDebugMode).
	ctx, cancel := context.WithTimeout(r.Context(), rpcTimeout)
	defer cancel()
	state, err := h.ai.SetTuning(ctx, &pb.SetTuningRequest{
		ConfidenceThreshold:    body.ConfidenceThreshold,
		IdleMinFramesWithHands: body.IdleMinFramesWithHands,
		IdleMotionStdThreshold: body.IdleMotionStdThreshold,
	})
	if err != nil {
		httpapi.WriteProblem(w, grpcProblem("updating tuning", err))
		return
	}
	writeJSON(w, tuningFromState(state))
}

// ---- prediction log ----

func (h *Handler) predictions(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	opts := predlog.QueryOptions{Word: q.Get("word")}
	var err error
	if opts.Limit, err = intParam(q.Get("limit"), 0); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid limit", err.Error()))
		return
	}
	if opts.Offset, err = intParam(q.Get("offset"), 0); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid offset", err.Error()))
		return
	}
	since, err := intParam(q.Get("since_ms"), 0)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid since_ms", err.Error()))
		return
	}
	opts.SinceMS = int64(since)

	records, err := h.store.List(opts)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Prediction log query failed", err.Error()))
		return
	}
	total, err := h.store.Count()
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Prediction log query failed", err.Error()))
		return
	}
	writeJSON(w, struct {
		Total   int64            `json:"total"`
		Records []predlog.Record `json:"records"`
	}{Total: total, Records: records})
}

func (h *Handler) clearPredictions(w http.ResponseWriter, r *http.Request) {
	if err := h.store.Clear(); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Failed to clear prediction log", err.Error()))
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- model upload ----

var uploadParts = []struct {
	field    string
	kind     pb.FileKind
	required bool
}{
	{"model", pb.FileKind_FILE_KIND_TFLITE_MODEL, true},
	{"label_map", pb.FileKind_FILE_KIND_LABEL_MAP, true},
	{"preprocess_config", pb.FileKind_FILE_KIND_PREPROCESS_CONFIG, false},
}

func (h *Handler) uploadModel(w http.ResponseWriter, r *http.Request) {
	r.Body = http.MaxBytesReader(w, r.Body, maxUploadBytes)
	if err := r.ParseMultipartForm(uploadMemoryBytes); err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Malformed multipart upload", err.Error()))
		return
	}
	defer r.MultipartForm.RemoveAll()

	ctx, cancel := context.WithTimeout(r.Context(), uploadTimeout)
	defer cancel()
	up, err := h.ai.UploadModel(ctx)
	if err != nil {
		httpapi.WriteProblem(w, grpcProblem("starting model upload", err))
		return
	}

	for _, part := range uploadParts {
		file, header, err := r.FormFile(part.field)
		if err != nil {
			if errors.Is(err, http.ErrMissingFile) && !part.required {
				continue
			}
			httpapi.WriteProblem(w, httpapi.NewProblem(
				http.StatusBadRequest, "Missing upload file",
				fmt.Sprintf("form field %q: %v", part.field, err)))
			return
		}
		if err := sendFile(up, part.kind, file, header); err != nil {
			file.Close()
			// The definitive gRPC status arrives at CloseAndRecv.
			if _, recvErr := up.CloseAndRecv(); recvErr != nil {
				err = recvErr
			}
			httpapi.WriteProblem(w, grpcProblem("uploading "+part.field, err))
			return
		}
		file.Close()
	}

	resp, err := up.CloseAndRecv()
	if err != nil {
		httpapi.WriteProblem(w, grpcProblem("finalizing model upload", err))
		return
	}
	log.Printf("admin: model upload live (%d classes, window %d, features %d)",
		resp.GetNumClasses(), resp.GetSequenceLen(), resp.GetFeatureDim())
	writeJSON(w, struct {
		Reloaded    bool   `json:"reloaded"`
		NumClasses  uint32 `json:"num_classes"`
		SequenceLen uint32 `json:"sequence_len"`
		FeatureDim  uint32 `json:"feature_dim"`
	}{resp.GetReloaded(), resp.GetNumClasses(), resp.GetSequenceLen(), resp.GetFeatureDim()})
}

func sendFile(
	up interface{ Send(*pb.UploadModelRequest) error },
	kind pb.FileKind,
	file multipart.File,
	header *multipart.FileHeader,
) error {
	err := up.Send(&pb.UploadModelRequest{
		Payload: &pb.UploadModelRequest_Header{Header: &pb.FileHeader{
			Kind:      kind,
			Filename:  header.Filename,
			SizeBytes: uint64(header.Size),
		}},
	})
	if err != nil {
		return err
	}
	for {
		buf := make([]byte, uploadChunkLen) // fresh buffer: Send retains it
		n, err := file.Read(buf)
		if n > 0 {
			sendErr := up.Send(&pb.UploadModelRequest{
				Payload: &pb.UploadModelRequest_Chunk{Chunk: buf[:n]},
			})
			if sendErr != nil {
				return sendErr
			}
		}
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
	}
}

// ---- AI service logs (SSE) ----

var logLevelValues = map[string]pb.LogLevel{
	"debug":   pb.LogLevel_LOG_LEVEL_DEBUG,
	"info":    pb.LogLevel_LOG_LEVEL_INFO,
	"warning": pb.LogLevel_LOG_LEVEL_WARNING,
	"error":   pb.LogLevel_LOG_LEVEL_ERROR,
}

var logLevelNames = map[pb.LogLevel]string{
	pb.LogLevel_LOG_LEVEL_DEBUG:   "DEBUG",
	pb.LogLevel_LOG_LEVEL_INFO:    "INFO",
	pb.LogLevel_LOG_LEVEL_WARNING: "WARNING",
	pb.LogLevel_LOG_LEVEL_ERROR:   "ERROR",
}

func (h *Handler) logs(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusInternalServerError, "Streaming unsupported",
			"response writer does not support flushing"))
		return
	}

	// Default: everything in Dev, info+ in Prod (Dev enables all debug).
	minLevel := pb.LogLevel_LOG_LEVEL_INFO
	if h.cfg.IsDev() {
		minLevel = pb.LogLevel_LOG_LEVEL_DEBUG
	}
	if v := r.URL.Query().Get("min_level"); v != "" {
		lvl, ok := logLevelValues[v]
		if !ok {
			httpapi.WriteProblem(w, httpapi.NewProblem(
				http.StatusBadRequest, "Invalid min_level",
				"expected one of: debug, info, warning, error"))
			return
		}
		minLevel = lvl
	}
	history, err := intParam(r.URL.Query().Get("history"), defaultLogHistory)
	if err != nil {
		httpapi.WriteProblem(w, httpapi.NewProblem(
			http.StatusBadRequest, "Invalid history", err.Error()))
		return
	}
	if history > maxLogHistory {
		history = maxLogHistory
	}

	// r.Context() ends when the browser closes the EventSource, which
	// cancels the proxied gRPC stream.
	logStream, err := h.ai.StreamLogs(r.Context(), &pb.StreamLogsRequest{
		MinLevel:     minLevel,
		HistoryLines: uint32(history),
	})
	if err != nil {
		httpapi.WriteProblem(w, grpcProblem("opening log stream", err))
		return
	}

	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-cache")
	w.WriteHeader(http.StatusOK)
	flusher.Flush()

	for {
		entry, err := logStream.Recv()
		if err != nil {
			return // client cancelled or AI stream ended; SSE just closes
		}
		payload, err := json.Marshal(struct {
			TimestampMS int64  `json:"timestamp_ms"`
			Level       string `json:"level"`
			Logger      string `json:"logger"`
			Message     string `json:"message"`
		}{
			TimestampMS: entry.GetTimestampMs(),
			Level:       logLevelNames[entry.GetLevel()],
			Logger:      entry.GetLogger(),
			Message:     entry.GetMessage(),
		})
		if err != nil {
			log.Printf("admin: encoding log entry: %v", err)
			continue
		}
		if _, err := fmt.Fprintf(w, "data: %s\n\n", payload); err != nil {
			return
		}
		flusher.Flush()
	}
}

// ---- helpers ----

func writeJSON(w http.ResponseWriter, v any) {
	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(v); err != nil {
		log.Printf("admin: writing JSON response: %v", err)
	}
}

func intParam(raw string, fallback int) (int, error) {
	if raw == "" {
		return fallback, nil
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return 0, fmt.Errorf("expected a non-negative integer, got %q", raw)
	}
	return n, nil
}

// grpcProblem maps a gRPC error onto an RFC 7807 problem.
func grpcProblem(op string, err error) httpapi.Problem {
	if s, ok := status.FromError(err); ok {
		switch s.Code() {
		case codes.InvalidArgument:
			return httpapi.NewProblem(http.StatusBadRequest,
				"Rejected by AI service", s.Message())
		case codes.FailedPrecondition:
			return httpapi.NewProblem(http.StatusConflict,
				"AI service precondition failed", s.Message())
		case codes.Unavailable, codes.DeadlineExceeded:
			return httpapi.NewProblem(http.StatusServiceUnavailable,
				"AI service unavailable", s.Message())
		}
	}
	return httpapi.NewProblem(http.StatusBadGateway,
		"AI service error", op+": "+err.Error())
}
