package stream

import (
	"context"
	"sync"
	"time"

	"gitea.harumi.dev/Harumi/NSC/backend/internal/llm"
	"gitea.harumi.dev/Harumi/NSC/backend/internal/pb"
)

// SentenceComposer turns the words of one signing burst into a spoken
// sentence. Implemented by *llm.Service.
type SentenceComposer interface {
	Compose(ctx context.Context, words []string) llm.Result
	Policy() llm.BufferPolicy
}

// sentenceBuffer collects recognized words for one WebSocket connection and
// composes them once the signer pauses. The pause — not the client — is what
// ends a sentence: the AI service emits a prediction per window, so silence
// shows up as a stretch with no new word rather than as an explicit event.
//
// Concurrency: observe runs on the prediction pump goroutine, flush on the
// pause timer's own goroutine. Everything touching words/timer holds mu, and
// the LLM call always happens after mu is released.
type sentenceBuffer struct {
	composer SentenceComposer
	ctx      context.Context
	send     func(any) bool

	mu     sync.Mutex
	words  []string
	last   string
	timer  *time.Timer
	closed bool
}

// newSentenceBuffer returns nil when no composer is wired; every method
// tolerates a nil receiver, so the caller needs no branch.
func newSentenceBuffer(ctx context.Context, composer SentenceComposer, send func(any) bool) *sentenceBuffer {
	if composer == nil {
		return nil
	}
	return &sentenceBuffer{composer: composer, ctx: ctx, send: send}
}

// observe feeds one prediction in. Idle and uncertain predictions carry no
// word, so they contribute nothing but let the pause timer run down.
func (b *sentenceBuffer) observe(p *pb.Prediction) {
	if b == nil || p.GetIsIdle() || p.GetIsUncertain() || p.GetWord() == "" {
		return
	}
	b.add(p.GetWord())
}

func (b *sentenceBuffer) add(word string) {
	policy := b.composer.Policy()

	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	// The AI service repeats its top-1 for every window of one gesture, so
	// only a change of word starts a new entry.
	if b.last == word {
		b.mu.Unlock()
		return
	}
	b.last = word
	b.words = append(b.words, word)

	if len(b.words) >= policy.MaxWords {
		words := b.drainLocked()
		b.mu.Unlock()
		// The pump goroutine must keep reading predictions during the call.
		go b.compose(words)
		return
	}
	if b.timer != nil {
		b.timer.Stop()
	}
	b.timer = time.AfterFunc(policy.Silence, b.flush)
	b.mu.Unlock()
}

// drainLocked returns the buffered words and clears the buffer. Caller holds mu.
func (b *sentenceBuffer) drainLocked() []string {
	words := b.words
	b.words = nil
	b.last = ""
	if b.timer != nil {
		b.timer.Stop()
		b.timer = nil
	}
	return words
}

// flush composes whatever the pause interrupted. It runs on the timer's
// goroutine, so the LLM call is allowed to block here.
func (b *sentenceBuffer) flush() {
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	words := b.drainLocked()
	b.mu.Unlock()
	if len(words) == 0 {
		return
	}
	b.compose(words)
}

func (b *sentenceBuffer) compose(words []string) {
	res := b.composer.Compose(b.ctx, words)
	if res.Sentence == "" {
		return
	}
	b.send(newSentenceMessage(words, res))
}

// reset drops the buffer without composing — the client restarted scanning,
// so the words in flight are no longer part of anything the signer is saying.
func (b *sentenceBuffer) reset() {
	if b == nil {
		return
	}
	b.mu.Lock()
	b.drainLocked()
	b.mu.Unlock()
}

// close stops the pause timer. Buffered words are dropped: the connection can
// no longer carry a sentence back.
func (b *sentenceBuffer) close() {
	if b == nil {
		return
	}
	b.mu.Lock()
	b.closed = true
	b.drainLocked()
	b.mu.Unlock()
}
