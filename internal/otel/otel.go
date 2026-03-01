// Package otel provides OpenTelemetry initialization utilities.
package otel

import (
	"context"
	"time"

	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploghttp"
	"go.opentelemetry.io/otel/log/global"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"

	"github.com/randomizedcoder/clickhouse-otel-example/internal/config"
)

// NewLoggerProvider creates and configures an OpenTelemetry logger provider.
// It sets the provider as the global provider and returns it along with a shutdown function.
func NewLoggerProvider(ctx context.Context, cfg *config.Config, serviceName, version string) (*sdklog.LoggerProvider, error) {
	opts := []otlploghttp.Option{
		otlploghttp.WithEndpoint(cfg.OTelEndpoint),
	}
	if cfg.OTelInsecure {
		opts = append(opts, otlploghttp.WithInsecure())
	}

	exporter, err := otlploghttp.New(ctx, opts...)
	if err != nil {
		return nil, err
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(serviceName),
			semconv.ServiceVersion(version),
		),
	)
	if err != nil {
		return nil, err
	}

	provider := sdklog.NewLoggerProvider(
		sdklog.WithProcessor(
			sdklog.NewBatchProcessor(exporter,
				sdklog.WithExportTimeout(5*time.Second),
			),
		),
		sdklog.WithResource(res),
	)

	global.SetLoggerProvider(provider)

	return provider, nil
}
