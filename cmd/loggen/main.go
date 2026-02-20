// Package main is the entry point for the loggen application.
// loggen generates structured JSON logs with random data for OpenTelemetry pipeline demos.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"

	"go.uber.org/zap"

	"github.com/randomizedcoder/clickhouse-otel-example/internal/config"
	"github.com/randomizedcoder/clickhouse-otel-example/internal/health"
	"github.com/randomizedcoder/clickhouse-otel-example/internal/loop"
)

// version is set at build time via ldflags.
var version = "dev"

func main() {
	os.Exit(run())
}

func run() int {
	// Load configuration from flags and environment variables
	cfg := config.Load()

	// Initialize production JSON logger
	logger, err := zap.NewProduction()
	if err != nil {
		// Fallback to stderr if logger creation fails
		os.Stderr.WriteString("failed to create logger: " + err.Error() + "\n")
		return 1
	}
	defer func() {
		_ = logger.Sync()
	}()

	logger.Info("loggen starting",
		zap.String("version", version),
		zap.Int("max_number", cfg.MaxNumber),
		zap.Int("num_strings", cfg.NumStrings),
		zap.Duration("sleep_duration", cfg.SleepDuration),
		zap.Int("health_port", cfg.HealthPort),
	)

	// Create cancellable context for coordinated shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Start health check server
	healthServer := health.NewServer(cfg.HealthPort, logger)
	go func() {
		if err := healthServer.Start(ctx); err != nil {
			logger.Error("health server failed", zap.Error(err))
			cancel()
		}
	}()

	// Start main logging loop
	looper := loop.New(cfg, logger)
	go looper.Run(ctx)

	// Wait for shutdown signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	sig := <-sigChan
	logger.Info("received shutdown signal", zap.String("signal", sig.String()))

	// Graceful shutdown
	cancel()

	// Shutdown health server
	if err := healthServer.Shutdown(context.Background()); err != nil {
		logger.Error("health server shutdown failed", zap.Error(err))
	}

	logger.Info("loggen stopped")
	return 0
}
