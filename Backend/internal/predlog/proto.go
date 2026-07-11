package predlog

import (
	"time"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

// FromProto converts an AI-service prediction into a storable Record,
// stamped with the current time.
func FromProto(p *pb.Prediction) Record {
	top := make([]ClassProb, 0, len(p.GetTop()))
	for _, c := range p.GetTop() {
		top = append(top, ClassProb{Label: c.GetLabel(), Prob: float64(c.GetProb())})
	}
	return Record{
		CreatedMS:       time.Now().UnixMilli(),
		Seq:             p.GetSeq(),
		Word:            p.GetWord(),
		Confidence:      float64(p.GetConfidence()),
		IsIdle:          p.GetIsIdle(),
		IsUncertain:     p.GetIsUncertain(),
		InferenceMicros: p.GetInferenceMicros(),
		OtherProb:       float64(p.GetOtherProb()),
		Top:             top,
	}
}
