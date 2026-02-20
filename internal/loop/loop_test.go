package loop

import (
	"context"
	"math/rand/v2"
	"testing"
	"time"

	"go.uber.org/zap/zaptest"

	"github.com/randomizedcoder/clickhouse-otel-example/internal/config"
)

func TestLooper_RandomNumber(t *testing.T) {
	cfg := &config.Config{MaxNumber: 100, NumStrings: 10}
	logger := zaptest.NewLogger(t)
	l := New(cfg, logger)

	// Test distribution
	counts := make(map[int]int)
	for i := 0; i < 10000; i++ {
		n := l.RandomNumber()
		if n < 0 || n > 100 {
			t.Errorf("RandomNumber() = %d, want [0, 100]", n)
		}
		counts[n]++
	}

	// Verify we see variety (statistical test)
	if len(counts) < 50 {
		t.Errorf("Poor distribution: only %d unique values in 10000 iterations", len(counts))
	}
}

func TestLooper_RandomNumber_EdgeCases(t *testing.T) {
	logger := zaptest.NewLogger(t)

	tests := []struct {
		name      string
		maxNumber int
		wantMax   int
	}{
		{"zero max", 0, 0},
		{"negative max", -5, 0},
		{"small max", 1, 1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &config.Config{MaxNumber: tt.maxNumber, NumStrings: 10}
			l := New(cfg, logger)

			for i := 0; i < 100; i++ {
				n := l.RandomNumber()
				if n < 0 || n > tt.wantMax {
					t.Errorf("RandomNumber() = %d, want [0, %d]", n, tt.wantMax)
				}
			}
		})
	}
}

func TestLooper_RandomString(t *testing.T) {
	logger := zaptest.NewLogger(t)

	tests := []struct {
		name       string
		numStrings int
		wantMax    int
	}{
		{"all strings", 10, 10},
		{"subset", 5, 5},
		{"minimum", 1, 1},
		{"more than available", 20, 10},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &config.Config{MaxNumber: 100, NumStrings: tt.numStrings}
			l := New(cfg, logger)

			seen := make(map[string]bool)
			for i := 0; i < 1000; i++ {
				s := l.RandomString()
				if s == "" {
					t.Error("RandomString() returned empty string")
				}
				seen[s] = true
			}

			if len(seen) > tt.wantMax {
				t.Errorf("saw %d unique strings, want at most %d", len(seen), tt.wantMax)
			}
		})
	}
}

func TestLooper_RandomString_EdgeCases(t *testing.T) {
	logger := zaptest.NewLogger(t)

	tests := []struct {
		name       string
		numStrings int
		wantEmpty  bool
	}{
		{"zero strings", 0, true},
		{"negative strings", -1, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg := &config.Config{MaxNumber: 100, NumStrings: tt.numStrings}
			l := New(cfg, logger)

			s := l.RandomString()
			if tt.wantEmpty && s != "" {
				t.Errorf("RandomString() = %q, want empty", s)
			}
		})
	}
}

func TestLooper_Run_Cancellation(t *testing.T) {
	cfg := &config.Config{
		MaxNumber:     100,
		NumStrings:    10,
		SleepDuration: 10 * time.Millisecond,
	}
	logger := zaptest.NewLogger(t)
	l := New(cfg, logger)

	ctx, cancel := context.WithCancel(context.Background())

	done := make(chan struct{})
	go func() {
		l.Run(ctx)
		close(done)
	}()

	// Let it tick a few times
	time.Sleep(50 * time.Millisecond)

	// Cancel and verify shutdown
	cancel()

	select {
	case <-done:
		// Success
	case <-time.After(time.Second):
		t.Error("Run() did not stop after context cancellation")
	}

	// Verify some ticks occurred
	if l.Count() == 0 {
		t.Error("Expected some ticks to occur")
	}
}

func TestLooper_Deterministic(t *testing.T) {
	cfg := &config.Config{MaxNumber: 100, NumStrings: 10}
	logger := zaptest.NewLogger(t)

	// Create two loopers with the same seed
	seed1, seed2 := uint64(12345), uint64(67890)
	rng1 := rand.New(rand.NewPCG(seed1, seed2))
	rng2 := rand.New(rand.NewPCG(seed1, seed2))

	l1 := NewWithRng(cfg, logger, rng1)
	l2 := NewWithRng(cfg, logger, rng2)

	// They should produce the same sequence
	for i := 0; i < 100; i++ {
		n1 := l1.RandomNumber()
		n2 := l2.RandomNumber()
		if n1 != n2 {
			t.Errorf("Iteration %d: RandomNumber() = %d, %d (should be same)", i, n1, n2)
		}

		s1 := l1.RandomString()
		s2 := l2.RandomString()
		if s1 != s2 {
			t.Errorf("Iteration %d: RandomString() = %q, %q (should be same)", i, s1, s2)
		}
	}
}
