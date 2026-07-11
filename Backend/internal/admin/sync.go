package admin

import (
	"context"
	"log"
	"time"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

// SyncDebugMode keeps the AI service's runtime debug_mode equal to dev
// (ENV=Dev in Backend/.env). It re-checks every interval because the AI
// service resets runtime tuning on restart and may not be up when the
// gateway starts. Runs until ctx is cancelled.
func SyncDebugMode(ctx context.Context, ai pb.TslInferenceClient, dev bool, interval time.Duration) {
	unreachable := false
	for {
		err := syncDebugModeOnce(ctx, ai, dev)
		switch {
		case err != nil && !unreachable:
			log.Printf("admin: cannot sync AI debug_mode (will keep retrying): %v", err)
			unreachable = true
		case err == nil && unreachable:
			log.Printf("admin: AI service reachable, debug_mode=%v", dev)
			unreachable = false
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(interval):
		}
	}
}

func syncDebugModeOnce(ctx context.Context, ai pb.TslInferenceClient, dev bool) error {
	rpcCtx, cancel := context.WithTimeout(ctx, rpcTimeout)
	defer cancel()
	state, err := ai.GetTuning(rpcCtx, &pb.GetTuningRequest{})
	if err != nil {
		return err
	}
	if state.GetDebugMode() == dev {
		return nil
	}
	if _, err := ai.SetTuning(rpcCtx, &pb.SetTuningRequest{DebugMode: &dev}); err != nil {
		return err
	}
	log.Printf("admin: AI debug_mode set to %v (ENV)", dev)
	return nil
}
