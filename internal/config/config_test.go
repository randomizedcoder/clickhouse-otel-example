package config

import (
	"os"
	"testing"
	"time"
)

func TestLoadWithDefaults(t *testing.T) {
	// Clear any env vars that might interfere
	os.Unsetenv("LOGGEN_MAX_NUMBER")
	os.Unsetenv("LOGGEN_NUM_STRINGS")
	os.Unsetenv("LOGGEN_SLEEP_DURATION")
	os.Unsetenv("LOGGEN_HEALTH_PORT")

	cfg := LoadWithDefaults()

	if cfg.MaxNumber != DefaultMaxNumber {
		t.Errorf("MaxNumber = %d, want %d", cfg.MaxNumber, DefaultMaxNumber)
	}
	if cfg.NumStrings != DefaultNumStrings {
		t.Errorf("NumStrings = %d, want %d", cfg.NumStrings, DefaultNumStrings)
	}
	if cfg.SleepDuration != DefaultSleepDuration {
		t.Errorf("SleepDuration = %v, want %v", cfg.SleepDuration, DefaultSleepDuration)
	}
	if cfg.HealthPort != DefaultHealthPort {
		t.Errorf("HealthPort = %d, want %d", cfg.HealthPort, DefaultHealthPort)
	}
}

func TestEnvOverrides(t *testing.T) {
	tests := []struct {
		name     string
		envKey   string
		envValue string
		check    func(*Config) bool
		desc     string
	}{
		{
			name:     "max number override",
			envKey:   "LOGGEN_MAX_NUMBER",
			envValue: "50",
			check:    func(c *Config) bool { return c.MaxNumber == 50 },
			desc:     "MaxNumber should be 50",
		},
		{
			name:     "num strings override",
			envKey:   "LOGGEN_NUM_STRINGS",
			envValue: "5",
			check:    func(c *Config) bool { return c.NumStrings == 5 },
			desc:     "NumStrings should be 5",
		},
		{
			name:     "sleep duration override",
			envKey:   "LOGGEN_SLEEP_DURATION",
			envValue: "10s",
			check:    func(c *Config) bool { return c.SleepDuration == 10*time.Second },
			desc:     "SleepDuration should be 10s",
		},
		{
			name:     "health port override",
			envKey:   "LOGGEN_HEALTH_PORT",
			envValue: "9090",
			check:    func(c *Config) bool { return c.HealthPort == 9090 },
			desc:     "HealthPort should be 9090",
		},
		{
			name:     "invalid max number ignored",
			envKey:   "LOGGEN_MAX_NUMBER",
			envValue: "invalid",
			check:    func(c *Config) bool { return c.MaxNumber == DefaultMaxNumber },
			desc:     "MaxNumber should remain default",
		},
		{
			name:     "negative max number ignored",
			envKey:   "LOGGEN_MAX_NUMBER",
			envValue: "-5",
			check:    func(c *Config) bool { return c.MaxNumber == DefaultMaxNumber },
			desc:     "MaxNumber should remain default for negative",
		},
		{
			name:     "zero num strings ignored",
			envKey:   "LOGGEN_NUM_STRINGS",
			envValue: "0",
			check:    func(c *Config) bool { return c.NumStrings == DefaultNumStrings },
			desc:     "NumStrings should remain default for zero",
		},
		{
			name:     "invalid duration ignored",
			envKey:   "LOGGEN_SLEEP_DURATION",
			envValue: "not-a-duration",
			check:    func(c *Config) bool { return c.SleepDuration == DefaultSleepDuration },
			desc:     "SleepDuration should remain default",
		},
		{
			name:     "invalid port ignored",
			envKey:   "LOGGEN_HEALTH_PORT",
			envValue: "99999",
			check:    func(c *Config) bool { return c.HealthPort == DefaultHealthPort },
			desc:     "HealthPort should remain default for out of range",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Clear all env vars
			os.Unsetenv("LOGGEN_MAX_NUMBER")
			os.Unsetenv("LOGGEN_NUM_STRINGS")
			os.Unsetenv("LOGGEN_SLEEP_DURATION")
			os.Unsetenv("LOGGEN_HEALTH_PORT")

			// Set the test env var
			os.Setenv(tt.envKey, tt.envValue)
			defer os.Unsetenv(tt.envKey)

			cfg := LoadWithDefaults()

			if !tt.check(cfg) {
				t.Errorf("%s failed: %s", tt.name, tt.desc)
			}
		})
	}
}
