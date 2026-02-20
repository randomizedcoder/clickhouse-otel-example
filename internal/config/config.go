// Package config handles application configuration from CLI flags and environment variables.
package config

import (
	"flag"
	"os"
	"strconv"
	"time"
)

// Config holds all application configuration.
type Config struct {
	// MaxNumber is the upper bound for random numbers [0, MaxNumber].
	MaxNumber int

	// NumStrings is how many strings from the predefined set to use.
	NumStrings int

	// SleepDuration is the interval between log emissions.
	SleepDuration time.Duration

	// HealthPort is the port for health check endpoints.
	HealthPort int
}

// Default values.
const (
	DefaultMaxNumber     = 100
	DefaultNumStrings    = 10
	DefaultSleepDuration = 5 * time.Second
	DefaultHealthPort    = 8081
)

// Load parses configuration from flags and environment variables.
// Environment variables override CLI flag defaults.
func Load() *Config {
	cfg := &Config{}

	flag.IntVar(&cfg.MaxNumber, "max-number", DefaultMaxNumber,
		"Maximum random number (env: LOGGEN_MAX_NUMBER)")
	flag.IntVar(&cfg.NumStrings, "num-strings", DefaultNumStrings,
		"Number of random strings to use (env: LOGGEN_NUM_STRINGS)")
	flag.DurationVar(&cfg.SleepDuration, "sleep-duration", DefaultSleepDuration,
		"Duration between log emissions (env: LOGGEN_SLEEP_DURATION)")
	flag.IntVar(&cfg.HealthPort, "health-port", DefaultHealthPort,
		"Port for health check server (env: LOGGEN_HEALTH_PORT)")

	flag.Parse()

	cfg.applyEnvOverrides()

	return cfg
}

// LoadWithDefaults returns a Config with default values without parsing flags.
// Useful for testing.
func LoadWithDefaults() *Config {
	cfg := &Config{
		MaxNumber:     DefaultMaxNumber,
		NumStrings:    DefaultNumStrings,
		SleepDuration: DefaultSleepDuration,
		HealthPort:    DefaultHealthPort,
	}
	cfg.applyEnvOverrides()
	return cfg
}

func (c *Config) applyEnvOverrides() {
	if v := os.Getenv("LOGGEN_MAX_NUMBER"); v != "" {
		if i, err := strconv.Atoi(v); err == nil && i >= 0 {
			c.MaxNumber = i
		}
	}

	if v := os.Getenv("LOGGEN_NUM_STRINGS"); v != "" {
		if i, err := strconv.Atoi(v); err == nil && i > 0 {
			c.NumStrings = i
		}
	}

	if v := os.Getenv("LOGGEN_SLEEP_DURATION"); v != "" {
		if d, err := time.ParseDuration(v); err == nil && d > 0 {
			c.SleepDuration = d
		}
	}

	if v := os.Getenv("LOGGEN_HEALTH_PORT"); v != "" {
		if i, err := strconv.Atoi(v); err == nil && i > 0 && i < 65536 {
			c.HealthPort = i
		}
	}
}
