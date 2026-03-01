// Package main is the entry point for the loggen application.
// loggen generates structured JSON logs with random data for OpenTelemetry pipeline demos.
package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.uber.org/zap"

	"github.com/randomizedcoder/clickhouse-otel-example/internal/config"
	"github.com/randomizedcoder/clickhouse-otel-example/internal/health"
	"github.com/randomizedcoder/clickhouse-otel-example/internal/loop"
	"github.com/randomizedcoder/clickhouse-otel-example/internal/otel"
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
		_, _ = os.Stderr.WriteString("failed to create logger: " + err.Error() + "\n")
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
		zap.String("otel_endpoint", cfg.OTelEndpoint),
	)

	// Create cancellable context for coordinated shutdown
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// Initialize OTel SDK for direct OTLP logging (Method 2)
	otelProvider, err := otel.NewLoggerProvider(ctx, cfg, "loggen", version)
	if err != nil {
		logger.Warn("failed to initialize OTel logger, Method 2 (OTLP) will be disabled",
			zap.Error(err))
	} else {
		logger.Info("OTel logger initialized", zap.String("endpoint", cfg.OTelEndpoint))
	}

	// Start health check server
	healthServer := health.NewServer(cfg.HealthPort, logger)
	go func() {
		if startErr := healthServer.Start(ctx); startErr != nil {
			logger.Error("health server failed", zap.Error(startErr))
			cancel()
		}
	}()

	// Start main logging loop with OTel logger
	looper := loop.New(cfg, logger)
	go looper.Run(ctx)

	// Wait for shutdown signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	sig := <-sigChan
	logger.Info("received shutdown signal", zap.String("signal", sig.String()))

	// Cancel main context to signal goroutines to stop
	cancel()

	// Create shutdown context with timeout for cleanup operations
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer shutdownCancel()

	// Shutdown OTel provider
	if otelProvider != nil {
		if shutdownErr := otelProvider.Shutdown(shutdownCtx); shutdownErr != nil {
			logger.Error("OTel shutdown failed", zap.Error(shutdownErr))
		}
	}

	// Shutdown health server
	if shutdownErr := healthServer.Shutdown(shutdownCtx); shutdownErr != nil {
		logger.Error("health server shutdown failed", zap.Error(shutdownErr))
	}

	logger.Info("loggen stopped")
	return 0
}
