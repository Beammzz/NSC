package stream

import (
	"gitea.harumi.dev/Harumi/NSC/backend/internal/httpapi"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

// WebSocket payload types for /api/v1/stream. Wire contract:
// docs/api/stream-schema.md (schema_version 1). Field changes there first.

const schemaVersion = 1

const (
	typeLandmarkFrame = "landmark_frame"
	typeReset         = "reset"
	typeReady         = "ready"
	typePrediction    = "prediction"
	typeError         = "error"
)

// featureDim mirrors the root Feature Vector Spec (Agents.md).
const featureDim = 441

type clientMessage struct {
	SchemaVersion int       `json:"schema_version"`
	Type          string    `json:"type"`
	Seq           uint64    `json:"seq"`
	TimestampMS   int64     `json:"timestamp_ms"`
	Features      []float32 `json:"features"`
}

type readyMessage struct {
	SchemaVersion int    `json:"schema_version"`
	Type          string `json:"type"`
}

type classProb struct {
	Label string  `json:"label"`
	Prob  float32 `json:"prob"`
}

type predictionMessage struct {
	SchemaVersion   int         `json:"schema_version"`
	Type            string      `json:"type"`
	Seq             uint64      `json:"seq"`
	Word            string      `json:"word"`
	Confidence      float32     `json:"confidence"`
	IsIdle          bool        `json:"is_idle"`
	IsUncertain     bool        `json:"is_uncertain"`
	Top             []classProb `json:"top"`
	InferenceMicros int64       `json:"inference_micros"`
}

type errorMessage struct {
	SchemaVersion int             `json:"schema_version"`
	Type          string          `json:"type"`
	Problem       httpapi.Problem `json:"problem"`
}

func newReadyMessage() readyMessage {
	return readyMessage{SchemaVersion: schemaVersion, Type: typeReady}
}

func newErrorMessage(p httpapi.Problem) errorMessage {
	return errorMessage{SchemaVersion: schemaVersion, Type: typeError, Problem: p}
}

func newPredictionMessage(p *pb.Prediction) predictionMessage {
	top := make([]classProb, 0, len(p.GetTop()))
	for _, c := range p.GetTop() {
		top = append(top, classProb{Label: c.GetLabel(), Prob: c.GetProb()})
	}
	return predictionMessage{
		SchemaVersion:   schemaVersion,
		Type:            typePrediction,
		Seq:             p.GetSeq(),
		Word:            p.GetWord(),
		Confidence:      p.GetConfidence(),
		IsIdle:          p.GetIsIdle(),
		IsUncertain:     p.GetIsUncertain(),
		Top:             top,
		InferenceMicros: p.GetInferenceMicros(),
	}
}
