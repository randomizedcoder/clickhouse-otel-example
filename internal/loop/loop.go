// Package loop implements the main logging loop that generates random data.
package loop

import (
	"context"
	"math/rand/v2"
	"time"

	"go.uber.org/zap"

	"github.com/randomizedcoder/clickhouse-otel-example/internal/config"
)

// DefaultStrings is the predefined set of random strings.
var DefaultStrings = []string{
	"alpha", "beta", "gamma", "delta", "epsilon",
	"zeta", "eta", "theta", "iota", "kappa",
}

// Looper handles the main logging loop.
type Looper struct {
	cfg    *config.Config
	logger *zap.Logger
	rng    *rand.Rand
	count  uint64
}

// New creates a new Looper instance.
func New(cfg *config.Config, logger *zap.Logger) *Looper {
	return &Looper{
		cfg:    cfg,
		logger: logger,
		rng:    rand.New(rand.NewPCG(uint64(time.Now().UnixNano()), uint64(time.Now().UnixNano()>>32))),
		count:  0,
	}
}

// NewWithRng creates a new Looper with a custom random source (for testing).
func NewWithRng(cfg *config.Config, logger *zap.Logger, rng *rand.Rand) *Looper {
	return &Looper{
		cfg:    cfg,
		logger: logger,
		rng:    rng,
		count:  0,
	}
}

// Run starts the logging loop, blocking until context is cancelled.
func (l *Looper) Run(ctx context.Context) {
	ticker := time.NewTicker(l.cfg.SleepDuration)
	defer ticker.Stop()

	l.logger.Info("loop started",
		zap.Duration("interval", l.cfg.SleepDuration),
		zap.Int("max_number", l.cfg.MaxNumber),
		zap.Int("num_strings", l.cfg.NumStrings),
	)

	for {
		select {
		case <-ctx.Done():
			l.logger.Info("loop stopped", zap.Uint64("total_ticks", l.count))
			return
		case <-ticker.C:
			l.tick()
		}
	}
}

// tick performs one iteration of the loop.
func (l *Looper) tick() {
	l.count++

	randomNum := l.RandomNumber()
	randomStr := l.RandomString()

	l.logger.Info("tick",
		zap.Uint64("count", l.count),
		zap.Int("random_number", randomNum),
		zap.String("random_string", randomStr),
	)
}

// RandomNumber returns a random integer in [0, MaxNumber].
func (l *Looper) RandomNumber() int {
	if l.cfg.MaxNumber <= 0 {
		return 0
	}
	return l.rng.IntN(l.cfg.MaxNumber + 1)
}

// RandomString returns a random string from the configured set.
func (l *Looper) RandomString() string {
	strings := l.getStrings()
	if len(strings) == 0 {
		return ""
	}
	return strings[l.rng.IntN(len(strings))]
}

// getStrings returns the slice of strings to use based on config.
func (l *Looper) getStrings() []string {
	if l.cfg.NumStrings <= 0 {
		return nil
	}
	if l.cfg.NumStrings >= len(DefaultStrings) {
		return DefaultStrings
	}
	return DefaultStrings[:l.cfg.NumStrings]
}

// Count returns the current tick count.
func (l *Looper) Count() uint64 {
	return l.count
}
