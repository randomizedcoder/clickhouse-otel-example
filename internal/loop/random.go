package loop

import (
	"crypto/rand"
	"math/big"
)

// RandomNumberInRange returns a random integer in [0, maxVal] using crypto/rand.
// This is a pure function for easy testing.
func RandomNumberInRange(maxVal int) int {
	if maxVal <= 0 {
		return 0
	}
	n, err := rand.Int(rand.Reader, big.NewInt(int64(maxVal+1)))
	if err != nil {
		return 0
	}
	return int(n.Int64())
}

// RandomStringFromSlice returns a random element from the slice using crypto/rand.
// This is a pure function for easy testing.
func RandomStringFromSlice(strings []string) string {
	if len(strings) == 0 {
		return ""
	}
	n, err := rand.Int(rand.Reader, big.NewInt(int64(len(strings))))
	if err != nil {
		return strings[0]
	}
	return strings[n.Int64()]
}
