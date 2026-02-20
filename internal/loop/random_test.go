package loop

import (
	"math/rand/v2"
	"testing"
)

func TestRandomNumberInRange(t *testing.T) {
	rng := rand.New(rand.NewPCG(42, 42))

	tests := []struct {
		name string
		max  int
	}{
		{"zero", 0},
		{"small", 10},
		{"large", 1000},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			for i := 0; i < 100; i++ {
				n := RandomNumberInRange(rng, tt.max)
				if tt.max <= 0 {
					if n != 0 {
						t.Errorf("RandomNumberInRange(%d) = %d, want 0", tt.max, n)
					}
				} else if n < 0 || n > tt.max {
					t.Errorf("RandomNumberInRange(%d) = %d, want [0, %d]", tt.max, n, tt.max)
				}
			}
		})
	}
}

func TestRandomNumberInRange_Negative(t *testing.T) {
	rng := rand.New(rand.NewPCG(42, 42))

	n := RandomNumberInRange(rng, -5)
	if n != 0 {
		t.Errorf("RandomNumberInRange(-5) = %d, want 0", n)
	}
}

func TestRandomStringFromSlice(t *testing.T) {
	rng := rand.New(rand.NewPCG(42, 42))

	t.Run("empty slice", func(t *testing.T) {
		s := RandomStringFromSlice(rng, nil)
		if s != "" {
			t.Errorf("RandomStringFromSlice(nil) = %q, want empty", s)
		}

		s = RandomStringFromSlice(rng, []string{})
		if s != "" {
			t.Errorf("RandomStringFromSlice([]) = %q, want empty", s)
		}
	})

	t.Run("single element", func(t *testing.T) {
		for i := 0; i < 10; i++ {
			s := RandomStringFromSlice(rng, []string{"only"})
			if s != "only" {
				t.Errorf("RandomStringFromSlice([only]) = %q, want 'only'", s)
			}
		}
	})

	t.Run("multiple elements", func(t *testing.T) {
		strings := []string{"a", "b", "c"}
		seen := make(map[string]bool)
		for i := 0; i < 100; i++ {
			s := RandomStringFromSlice(rng, strings)
			seen[s] = true
			// Verify it's from the input
			found := false
			for _, valid := range strings {
				if s == valid {
					found = true
					break
				}
			}
			if !found {
				t.Errorf("RandomStringFromSlice returned %q, not in input slice", s)
			}
		}
		if len(seen) != 3 {
			t.Errorf("expected all 3 strings to be selected, got %d", len(seen))
		}
	})
}

func TestRandomStringFromSlice_Distribution(t *testing.T) {
	rng := rand.New(rand.NewPCG(12345, 67890))
	strings := []string{"a", "b", "c", "d", "e"}
	counts := make(map[string]int)

	iterations := 10000
	for i := 0; i < iterations; i++ {
		s := RandomStringFromSlice(rng, strings)
		counts[s]++
	}

	// Each string should appear roughly 20% of the time (2000 times)
	// Allow for some variance (15% - 25%)
	minExpected := iterations / 10     // 10%
	maxExpected := iterations * 3 / 10 // 30%

	for _, s := range strings {
		count := counts[s]
		if count < minExpected || count > maxExpected {
			t.Errorf("String %q appeared %d times, expected roughly %d (between %d and %d)",
				s, count, iterations/len(strings), minExpected, maxExpected)
		}
	}
}
