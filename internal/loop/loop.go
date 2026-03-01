// Package loop implements the main logging loop that generates random data.
package loop

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"math/big"
	"os"
	"time"

	"go.opentelemetry.io/otel/log"
	"go.opentelemetry.io/otel/log/global"
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
	cfg        *config.Config
	logger     *zap.Logger
	otelLogger log.Logger
	count      uint64
}

// New creates a new Looper instance.
func New(cfg *config.Config, logger *zap.Logger) *Looper {
	otelLogger := global.GetLoggerProvider().Logger("loggen")
	return &Looper{
		cfg:        cfg,
		logger:     logger,
		otelLogger: otelLogger,
		count:      0,
	}
}

// Run starts the logging loop, blocking until context is canceled.
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
			l.tick(ctx)
		}
	}
}

// tick performs one iteration of the loop.
// It emits logs via three different methods for comparison:
// - Method 1: FluentBit+Lua (Zap to stdout)
// - Method 2: OTLP Direct (OTel SDK to Collector)
// - Method 3: Collector Filelog (JSON to stdout)
func (l *Looper) tick(ctx context.Context) {
	l.count++
	count := l.count
	randomNum := l.RandomNumber()
	randomStr := l.RandomString()

	// All three methods log the same data with different paths
	l.logViaZap(count, randomNum, randomStr)       // Method 1: FluentBit+Lua
	l.logViaOTLP(ctx, count, randomNum, randomStr) // Method 2: OTLP direct
	l.logViaFileJSON(count, randomNum, randomStr)  // Method 3: Collector filelog
}

// logViaZap emits logs using Zap (Method 1: FluentBit+Lua pipeline).
// These logs go to stdout, are collected by FluentBit, transformed by Lua,
// and inserted into ClickHouse.
// The message body "FluentBit" is used to identify this method in queries.
func (l *Looper) logViaZap(count uint64, randomNum int, randomStr string) {
	l.logger.Info("tick via FluentBit+Lua pipeline",
		zap.Uint64("count", count),
		zap.Int("random_number", randomNum),
		zap.String("random_string", randomStr),
	)
}

// logViaOTLP emits logs using OTel SDK directly to the Collector (Method 2).
// These logs bypass stdout and go directly via OTLP to the OTel Collector,
// which inserts them into ClickHouse.
// The message body "OTLP direct" is used to identify this method in queries.
func (l *Looper) logViaOTLP(ctx context.Context, count uint64, randomNum int, randomStr string) {
	if l.otelLogger == nil {
		return
	}

	var record log.Record
	record.SetTimestamp(time.Now())
	record.SetBody(log.StringValue("tick via OTLP direct to Collector"))
	record.SetSeverity(log.SeverityInfo)
	record.AddAttributes(
		log.Int64("count", int64(count)),
		log.Int("random_number", randomNum),
		log.String("random_string", randomStr),
	)
	l.otelLogger.Emit(ctx, record)
}

// logViaFileJSON emits OTel-structured JSON to stdout for the Collector's filelog receiver (Method 3).
// These logs are written to stdout as JSON, collected by the OTel Collector's filelog receiver,
// and inserted into ClickHouse.
// The message body "filelog receiver" is used to identify this method in queries.
func (l *Looper) logViaFileJSON(count uint64, randomNum int, randomStr string) {
	entry := map[string]any{
		"timestamp":      time.Now().UTC().Format(time.RFC3339Nano),
		"ts":             float64(time.Now().UnixNano()) / 1e9,
		"level":          "info",
		"severity":       "INFO",
		"severityNumber": 9,
		"body":           "tick via Collector filelog receiver",
		"msg":            "tick via Collector filelog receiver",
		"count":          count,
		"random_number":  randomNum,
		"random_string":  randomStr,
	}
	_ = json.NewEncoder(os.Stdout).Encode(entry)
}

// RandomNumber returns a random integer in [0, MaxNumber] using crypto/rand.
func (l *Looper) RandomNumber() int {
	if l.cfg.MaxNumber <= 0 {
		return 0
	}
	n, err := rand.Int(rand.Reader, big.NewInt(int64(l.cfg.MaxNumber+1)))
	if err != nil {
		// Fallback to 0 on error (should never happen with Reader)
		return 0
	}
	return int(n.Int64())
}

// RandomString returns a random string from the configured set using crypto/rand.
func (l *Looper) RandomString() string {
	strings := l.getStrings()
	if len(strings) == 0 {
		return ""
	}
	n, err := rand.Int(rand.Reader, big.NewInt(int64(len(strings))))
	if err != nil {
		// Fallback to first string on error (should never happen with Reader)
		return strings[0]
	}
	return strings[n.Int64()]
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
