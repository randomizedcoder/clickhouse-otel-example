package loop

import (
	"math/rand/v2"
)

// RandomNumberInRange returns a random integer in [0, max].
// This is a pure function for easy testing.
func RandomNumberInRange(rng *rand.Rand, max int) int {
	if max <= 0 {
		return 0
	}
	return rng.IntN(max + 1)
}

// RandomStringFromSlice returns a random element from the slice.
// This is a pure function for easy testing.
func RandomStringFromSlice(rng *rand.Rand, strings []string) string {
	if len(strings) == 0 {
		return ""
	}
	return strings[rng.IntN(len(strings))]
}
