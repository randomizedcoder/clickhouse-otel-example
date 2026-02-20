# ClickHouse OpenTelemetry Pipeline - Design Document

**Version:** 1.0
**Date:** 2026-02-18
**Status:** Draft

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [High-Level Architecture](#2-high-level-architecture)
   - 2.1 [System Overview](#21-system-overview)
   - 2.2 [Data Flow](#22-data-flow)
   - 2.3 [Component Diagram](#23-component-diagram)
3. [Go Application Design](#3-go-application-design)
   - 3.1 [Package Structure](#31-package-structure)
   - 3.2 [Module: main](#32-module-main)
   - 3.3 [Module: loop](#33-module-loop)
   - 3.4 [Module: health](#34-module-health)
   - 3.5 [Configuration Management](#35-configuration-management)
   - 3.6 [Logging Strategy](#36-logging-strategy)
   - 3.7 [Testing Strategy](#37-testing-strategy)
   - 3.8 [Code Specifications](#38-code-specifications)
4. [Nix Design](#4-nix-design)
   - 4.1 [Flake Structure](#41-flake-structure)
   - 4.2 [Go Package Derivation](#42-go-package-derivation)
   - 4.3 [FluentBit Derivation](#43-fluentbit-derivation)
   - 4.4 [ClickHouse Derivation](#44-clickhouse-derivation)
   - 4.5 [HyperDX Derivation](#45-hyperdx-derivation)
   - 4.6 [Development Shell](#46-development-shell)
5. [Container Design](#5-container-design)
   - 5.1 [Container Philosophy](#51-container-philosophy)
   - 5.2 [Go Application Container](#52-go-application-container)
   - 5.3 [FluentBit Container](#53-fluentbit-container)
   - 5.4 [ClickHouse Container](#54-clickhouse-container)
   - 5.5 [HyperDX Container](#55-hyperdx-container)
   - 5.6 [Container Registry Strategy](#56-container-registry-strategy)
6. [FluentBit Pipeline Design](#6-fluentbit-pipeline-design)
   - 6.1 [Log Collection](#61-log-collection)
   - 6.2 [Lua Transformation Script](#62-lua-transformation-script)
   - 6.3 [ClickHouse Output](#63-clickhouse-output)
7. [ClickHouse Schema Design](#7-clickhouse-schema-design)
   - 7.1 [HyperDX Native Schema](#71-hyperdx-native-schema)
   - 7.2 [Initialization Scripts](#72-initialization-scripts)
8. [MicroVM Design](#8-microvm-design)
   - 8.1 [VM Configuration](#81-vm-configuration)
   - 8.2 [Network Configuration](#82-network-configuration)
   - 8.3 [Container Image Loading](#83-container-image-loading)
   - 8.4 [Minikube Integration](#84-minikube-integration)
9. [Kubernetes Manifests](#9-kubernetes-manifests)
   - 9.1 [Namespace Organization](#91-namespace-organization)
   - 9.2 [Go Application Deployment](#92-go-application-deployment)
   - 9.3 [FluentBit DaemonSet](#93-fluentbit-daemonset)
   - 9.4 [ClickHouse StatefulSet](#94-clickhouse-statefulset)
   - 9.5 [HyperDX Deployment](#95-hyperdx-deployment)
10. [Testing Strategy](#10-testing-strategy)
    - 10.1 [Unit Tests](#101-unit-tests)
    - 10.2 [Integration Tests](#102-integration-tests)
    - 10.3 [End-to-End Tests](#103-end-to-end-tests)
11. [Build and Deployment](#11-build-and-deployment)
    - 11.1 [Build Commands](#111-build-commands)
    - 11.2 [Deployment Workflow](#112-deployment-workflow)
12. [Appendices](#12-appendices)
    - A. [Directory Structure](#appendix-a-directory-structure)
    - B. [Environment Variables](#appendix-b-environment-variables)
    - C. [Port Mappings](#appendix-c-port-mappings)

---

## 1. Executive Summary

This document describes the design of a demonstration OpenTelemetry logs pipeline using:

- **Go Application**: Generates structured JSON logs with random data
- **FluentBit**: Collects, transforms, and forwards logs
- **ClickHouse**: Stores logs in OTel-compatible schema
- **HyperDX**: Provides log visualization and querying
- **Minikube**: Orchestrates containers in Kubernetes
- **MicroVM**: Runs the entire stack in an isolated VM
- **Nix**: Builds all components reproducibly

The pipeline demonstrates operational debugging workflows where logs contain aggregatable fields (numbers 0-100, categorical strings) enabling analytical queries.

---

## 2. High-Level Architecture

### 2.1 System Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              Host Machine                                    │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │                     MicroVM (QEMU) - 8GB RAM, 4 CPUs                  │  │
│  │  ┌─────────────────────────────────────────────────────────────────┐  │  │
│  │  │                         Minikube Cluster                        │  │  │
│  │  │                                                                 │  │  │
│  │  │  ┌─────────────┐    ┌─────────────┐    ┌─────────────────────┐  │  │  │
│  │  │  │   Go App    │    │  FluentBit  │    │     ClickHouse      │  │  │  │
│  │  │  │  (Pod)      │───▶│ (DaemonSet) │───▶│   (StatefulSet)     │  │  │  │
│  │  │  │             │    │             │    │                     │  │  │  │
│  │  │  │ JSON Logs   │    │ Lua → OTel  │    │   otel_logs table   │  │  │  │
│  │  │  └─────────────┘    └─────────────┘    └──────────┬──────────┘  │  │  │
│  │  │                                                    │            │  │  │
│  │  │                                         ┌──────────▼──────────┐ │  │  │
│  │  │                                         │      HyperDX       │ │  │  │
│  │  │                                         │   (Deployment)     │ │  │  │
│  │  │                                         │                    │ │  │  │
│  │  │                                         │   Query & Visualize│ │  │  │
│  │  │                                         └────────────────────┘ │  │  │
│  │  └─────────────────────────────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  Port Forwards: 28080 (HyperDX UI), 28123 (ClickHouse HTTP), 29000 (CH Native) │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 2.2 Data Flow

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              Data Flow Pipeline                               │
└──────────────────────────────────────────────────────────────────────────────┘

Step 1: Log Generation
┌─────────────────────────────────────────────────────────────────────────────┐
│  Go App generates JSON log every 5 seconds:                                  │
│  {                                                                           │
│    "level": "info",                                                          │
│    "ts": 1708272000.123456,                                                  │
│    "caller": "loop/loop.go:42",                                              │
│    "msg": "tick",                                                            │
│    "count": 1,                                                               │
│    "random_number": 42,                                                      │
│    "random_string": "gamma"                                                  │
│  }                                                                           │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
Step 2: Log Collection (FluentBit tail input)
┌─────────────────────────────────────────────────────────────────────────────┐
│  FluentBit reads from: /var/log/containers/go-app-*.log                      │
│  Kubernetes container log format (JSON wrapped):                             │
│  {"log":"{\"level\":\"info\",...}","stream":"stdout","time":"..."}          │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
Step 3: Lua Transformation
┌─────────────────────────────────────────────────────────────────────────────┐
│  Lua script converts to OTel Log format:                                     │
│  - Extract timestamp → TimeUnixNano                                          │
│  - Map level → SeverityNumber + SeverityText                                 │
│  - Extract body → Body                                                       │
│  - Map fields → Attributes (random_number, random_string)                    │
│  - Add resource attributes (service.name, k8s.pod.name, etc.)               │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
Step 4: ClickHouse Insert
┌─────────────────────────────────────────────────────────────────────────────┐
│  FluentBit HTTP output to ClickHouse:                                        │
│  INSERT INTO otel_logs (Timestamp, Body, SeverityText, ...)                 │
│  Using HyperDX native schema for full UI compatibility                       │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
Step 5: Query & Visualization
┌─────────────────────────────────────────────────────────────────────────────┐
│  HyperDX queries ClickHouse:                                                 │
│  - Search: random_number:42 AND random_string:gamma                         │
│  - Aggregate: COUNT(*) GROUP BY random_string                               │
│  - Time series: logs per minute with specific values                        │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 2.3 Component Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           Component Responsibilities                         │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐  ┌──────────────┐
│    GO-APP       │  │   FLUENTBIT     │  │   CLICKHOUSE    │  │   HYPERDX    │
├─────────────────┤  ├─────────────────┤  ├─────────────────┤  ├──────────────┤
│ Responsibilities│  │ Responsibilities│  │ Responsibilities│  │Responsibilities
│                 │  │                 │  │                 │  │              │
│ • Generate logs │  │ • Tail logs     │  │ • Store logs    │  │ • Query logs │
│ • Random data   │  │ • Parse JSON    │  │ • Index data    │  │ • Visualize  │
│ • Health check  │  │ • Transform Lua │  │ • Execute SQL   │  │ • Aggregate  │
│ • Graceful stop │  │ • Buffer/retry  │  │ • Retention     │  │ • Search     │
│                 │  │ • Output to CH  │  │                 │  │              │
├─────────────────┤  ├─────────────────┤  ├─────────────────┤  ├──────────────┤
│ Ports           │  │ Ports           │  │ Ports           │  │ Ports        │
│ • 8081 (health) │  │ • 2020 (metrics)│  │ • 8123 (HTTP)   │  │ • 8080 (UI)  │
│                 │  │ • 2021 (health) │  │ • 9000 (Native) │  │ • 8000 (API) │
│                 │  │                 │  │ • 9009 (Inter)  │  │              │
└─────────────────┘  └─────────────────┘  └─────────────────┘  └──────────────┘
```

---

## 3. Go Application Design

### 3.1 Package Structure

```
cmd/
└── loggen/
    └── main.go           # Entry point, signal handling, CLI flags

internal/
├── loop/
│   ├── loop.go           # Core loop logic
│   ├── loop_test.go      # Unit tests
│   ├── random.go         # Random generators
│   └── random_test.go    # Random generator tests
├── health/
│   ├── health.go         # HTTP health server
│   └── health_test.go    # Health server tests
└── config/
    ├── config.go         # Configuration loading
    └── config_test.go    # Config tests

go.mod
go.sum
```

### 3.2 Module: main

**File:** `cmd/loggen/main.go`

**Responsibilities:**
- Parse CLI flags with environment variable fallbacks
- Initialize zap logger
- Start health check server
- Start main loop
- Handle SIGINT/SIGTERM for graceful shutdown

**Design:**

```go
package main

import (
    "context"
    "flag"
    "os"
    "os/signal"
    "syscall"

    "go.uber.org/zap"

    "github.com/example/loggen/internal/config"
    "github.com/example/loggen/internal/health"
    "github.com/example/loggen/internal/loop"
)

func main() {
    // 1. Load configuration (flags + env vars)
    cfg := config.Load()

    // 2. Initialize zap logger (production JSON config)
    logger, _ := zap.NewProduction()
    defer logger.Sync()

    // 3. Create cancellable context for shutdown
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    // 4. Start health server (non-blocking)
    healthServer := health.NewServer(cfg.HealthPort, logger)
    go healthServer.Start(ctx)

    // 5. Start main loop (non-blocking)
    looper := loop.New(cfg, logger)
    go looper.Run(ctx)

    // 6. Wait for shutdown signal
    sigChan := make(chan os.Signal, 1)
    signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
    <-sigChan

    // 7. Graceful shutdown
    logger.Info("shutting down")
    cancel()
    healthServer.Shutdown(ctx)
}
```

### 3.3 Module: loop

**File:** `internal/loop/loop.go`

**Responsibilities:**
- Run periodic logging loop
- Generate random numbers within configured range
- Select random strings from predefined set
- Maintain tick counter

**Design:**

```go
package loop

import (
    "context"
    "math/rand"
    "time"

    "go.uber.org/zap"

    "github.com/example/loggen/internal/config"
)

// Predefined strings for random selection
var DefaultStrings = []string{
    "alpha", "beta", "gamma", "delta", "epsilon",
    "zeta", "eta", "theta", "iota", "kappa",
}

// Looper handles the main logging loop
type Looper struct {
    cfg    *config.Config
    logger *zap.Logger
    rng    *rand.Rand
    count  uint64
}

// New creates a new Looper instance
func New(cfg *config.Config, logger *zap.Logger) *Looper {
    return &Looper{
        cfg:    cfg,
        logger: logger,
        rng:    rand.New(rand.NewSource(time.Now().UnixNano())),
        count:  0,
    }
}

// Run starts the logging loop, blocking until context is cancelled
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
            l.tick()
        }
    }
}

// tick performs one iteration of the loop
func (l *Looper) tick() {
    l.count++

    randomNum := l.RandomNumber()
    randomStr := l.RandomString()

    l.logger.Info("tick",
        zap.Uint64("count", l.count),
        zap.Int("random_number", randomNum),
        zap.String("random_string", randomStr),
    )
}

// RandomNumber returns a random integer in [0, MaxNumber]
func (l *Looper) RandomNumber() int {
    return l.rng.Intn(l.cfg.MaxNumber + 1)
}

// RandomString returns a random string from the configured set
func (l *Looper) RandomString() string {
    strings := l.getStrings()
    return strings[l.rng.Intn(len(strings))]
}

// getStrings returns the slice of strings to use based on config
func (l *Looper) getStrings() []string {
    if l.cfg.NumStrings >= len(DefaultStrings) {
        return DefaultStrings
    }
    return DefaultStrings[:l.cfg.NumStrings]
}
```

**File:** `internal/loop/random.go`

```go
package loop

import (
    "math/rand"
)

// RandomNumberInRange returns a random integer in [0, max]
// This is a pure function for easy testing
func RandomNumberInRange(rng *rand.Rand, max int) int {
    if max <= 0 {
        return 0
    }
    return rng.Intn(max + 1)
}

// RandomStringFromSlice returns a random element from the slice
// This is a pure function for easy testing
func RandomStringFromSlice(rng *rand.Rand, strings []string) string {
    if len(strings) == 0 {
        return ""
    }
    return strings[rng.Intn(len(strings))]
}
```

### 3.4 Module: health

**File:** `internal/health/health.go`

**Responsibilities:**
- Provide `/health` endpoint for liveness probes
- Provide `/ready` endpoint for readiness probes
- Graceful server shutdown

**Design:**

```go
package health

import (
    "context"
    "fmt"
    "net/http"
    "sync/atomic"
    "time"

    "go.uber.org/zap"
)

// Server provides health check endpoints
type Server struct {
    port   int
    logger *zap.Logger
    server *http.Server
    ready  atomic.Bool
}

// NewServer creates a new health check server
func NewServer(port int, logger *zap.Logger) *Server {
    s := &Server{
        port:   port,
        logger: logger,
    }
    s.ready.Store(true)
    return s
}

// Start begins serving health endpoints (blocking)
func (s *Server) Start(ctx context.Context) {
    mux := http.NewServeMux()
    mux.HandleFunc("/health", s.handleHealth)
    mux.HandleFunc("/ready", s.handleReady)

    s.server = &http.Server{
        Addr:         fmt.Sprintf(":%d", s.port),
        Handler:      mux,
        ReadTimeout:  5 * time.Second,
        WriteTimeout: 5 * time.Second,
    }

    s.logger.Info("health server starting", zap.Int("port", s.port))

    if err := s.server.ListenAndServe(); err != http.ErrServerClosed {
        s.logger.Error("health server error", zap.Error(err))
    }
}

// Shutdown gracefully stops the server
func (s *Server) Shutdown(ctx context.Context) error {
    s.ready.Store(false)

    shutdownCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()

    return s.server.Shutdown(shutdownCtx)
}

// SetReady updates the readiness status
func (s *Server) SetReady(ready bool) {
    s.ready.Store(ready)
}

func (s *Server) handleHealth(w http.ResponseWriter, r *http.Request) {
    w.WriteHeader(http.StatusOK)
    w.Write([]byte("ok"))
}

func (s *Server) handleReady(w http.ResponseWriter, r *http.Request) {
    if s.ready.Load() {
        w.WriteHeader(http.StatusOK)
        w.Write([]byte("ready"))
    } else {
        w.WriteHeader(http.StatusServiceUnavailable)
        w.Write([]byte("not ready"))
    }
}
```

### 3.5 Configuration Management

**File:** `internal/config/config.go`

**Design Principles:**
- CLI flags are the primary configuration method
- Environment variables override CLI defaults
- Sensible defaults for all values

```go
package config

import (
    "flag"
    "os"
    "strconv"
    "time"
)

// Config holds all application configuration
type Config struct {
    // MaxNumber is the upper bound for random numbers [0, MaxNumber]
    MaxNumber int

    // NumStrings is how many strings from the predefined set to use
    NumStrings int

    // SleepDuration is the interval between log emissions
    SleepDuration time.Duration

    // HealthPort is the port for health check endpoints
    HealthPort int
}

// Default values
const (
    DefaultMaxNumber     = 100
    DefaultNumStrings    = 10
    DefaultSleepDuration = 5 * time.Second
    DefaultHealthPort    = 8081
)

// Load parses configuration from flags and environment variables
func Load() *Config {
    cfg := &Config{}

    // Define flags with defaults
    flag.IntVar(&cfg.MaxNumber, "max-number", DefaultMaxNumber,
        "Maximum random number (env: LOGGEN_MAX_NUMBER)")
    flag.IntVar(&cfg.NumStrings, "num-strings", DefaultNumStrings,
        "Number of random strings to use (env: LOGGEN_NUM_STRINGS)")
    flag.DurationVar(&cfg.SleepDuration, "sleep-duration", DefaultSleepDuration,
        "Duration between log emissions (env: LOGGEN_SLEEP_DURATION)")
    flag.IntVar(&cfg.HealthPort, "health-port", DefaultHealthPort,
        "Port for health check server (env: LOGGEN_HEALTH_PORT)")

    flag.Parse()

    // Override with environment variables if set
    cfg.applyEnvOverrides()

    return cfg
}

func (c *Config) applyEnvOverrides() {
    if v := os.Getenv("LOGGEN_MAX_NUMBER"); v != "" {
        if i, err := strconv.Atoi(v); err == nil {
            c.MaxNumber = i
        }
    }

    if v := os.Getenv("LOGGEN_NUM_STRINGS"); v != "" {
        if i, err := strconv.Atoi(v); err == nil {
            c.NumStrings = i
        }
    }

    if v := os.Getenv("LOGGEN_SLEEP_DURATION"); v != "" {
        if d, err := time.ParseDuration(v); err == nil {
            c.SleepDuration = d
        }
    }

    if v := os.Getenv("LOGGEN_HEALTH_PORT"); v != "" {
        if i, err := strconv.Atoi(v); err == nil {
            c.HealthPort = i
        }
    }
}
```

### 3.6 Logging Strategy

**Logger Configuration:**
- Use `zap.NewProduction()` for JSON output
- All logs go to stdout (Kubernetes standard)
- Structured fields for queryability

**Log Fields Standard:**

| Field | Type | Description |
|-------|------|-------------|
| `level` | string | Log level (info, error, etc.) |
| `ts` | float64 | Unix timestamp with nanoseconds |
| `caller` | string | File:line of log call |
| `msg` | string | Log message |
| `count` | uint64 | Tick counter |
| `random_number` | int | Random number [0, MaxNumber] |
| `random_string` | string | Random string from set |

**Example Output:**
```json
{"level":"info","ts":1708272000.123456789,"caller":"loop/loop.go:52","msg":"tick","count":1,"random_number":42,"random_string":"gamma"}
```

### 3.7 Testing Strategy

**Unit Tests Coverage:**

| Package | Test File | Coverage Target |
|---------|-----------|-----------------|
| `loop` | `loop_test.go` | 90%+ |
| `loop` | `random_test.go` | 100% |
| `health` | `health_test.go` | 85%+ |
| `config` | `config_test.go` | 90%+ |

**File:** `internal/loop/loop_test.go`

```go
package loop_test

import (
    "context"
    "testing"
    "time"

    "go.uber.org/zap"
    "go.uber.org/zap/zaptest"

    "github.com/example/loggen/internal/config"
    "github.com/example/loggen/internal/loop"
)

func TestLooper_RandomNumber(t *testing.T) {
    cfg := &config.Config{MaxNumber: 100}
    logger := zaptest.NewLogger(t)
    l := loop.New(cfg, logger)

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
        t.Errorf("Poor distribution: only %d unique values", len(counts))
    }
}

func TestLooper_RandomString(t *testing.T) {
    tests := []struct {
        name       string
        numStrings int
        wantLen    int
    }{
        {"all strings", 10, 10},
        {"subset", 5, 5},
        {"minimum", 1, 1},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            cfg := &config.Config{NumStrings: tt.numStrings}
            logger := zaptest.NewLogger(t)
            l := loop.New(cfg, logger)

            seen := make(map[string]bool)
            for i := 0; i < 1000; i++ {
                s := l.RandomString()
                seen[s] = true
            }

            if len(seen) > tt.wantLen {
                t.Errorf("saw %d unique strings, want at most %d", len(seen), tt.wantLen)
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
    l := loop.New(cfg, logger)

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
}
```

**File:** `internal/loop/random_test.go`

```go
package loop_test

import (
    "math/rand"
    "testing"

    "github.com/example/loggen/internal/loop"
)

func TestRandomNumberInRange(t *testing.T) {
    rng := rand.New(rand.NewSource(42))

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
                n := loop.RandomNumberInRange(rng, tt.max)
                if n < 0 || n > tt.max {
                    t.Errorf("RandomNumberInRange(%d) = %d, want [0, %d]", tt.max, n, tt.max)
                }
            }
        })
    }
}

func TestRandomStringFromSlice(t *testing.T) {
    rng := rand.New(rand.NewSource(42))

    t.Run("empty slice", func(t *testing.T) {
        s := loop.RandomStringFromSlice(rng, nil)
        if s != "" {
            t.Errorf("RandomStringFromSlice(nil) = %q, want empty", s)
        }
    })

    t.Run("single element", func(t *testing.T) {
        s := loop.RandomStringFromSlice(rng, []string{"only"})
        if s != "only" {
            t.Errorf("RandomStringFromSlice([only]) = %q, want 'only'", s)
        }
    })

    t.Run("multiple elements", func(t *testing.T) {
        strings := []string{"a", "b", "c"}
        seen := make(map[string]bool)
        for i := 0; i < 100; i++ {
            s := loop.RandomStringFromSlice(rng, strings)
            seen[s] = true
        }
        if len(seen) != 3 {
            t.Errorf("expected all 3 strings to be selected, got %d", len(seen))
        }
    })
}
```

### 3.8 Code Specifications

**Go Version:** 1.26+

**Dependencies:**

| Module | Version | Purpose |
|--------|---------|---------|
| `go.uber.org/zap` | v1.27.0 | Structured logging |

**Code Style:**
- Follow `gofmt` and `goimports`
- Use `golangci-lint` with default configuration
- No global state except `DefaultStrings` constant
- All public functions documented
- Context-aware cancellation throughout

**Build Tags:**
- None required (pure Go, no CGO)

---

## 4. Nix Design

### 4.1 Flake Structure

**File:** `flake.nix`

```nix
{
  description = "ClickHouse OpenTelemetry Pipeline Demo";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    microvm = {
      url = "github:astro/microvm.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, flake-utils, microvm }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        };

        # Import our modules
        goApp = import ./nix/go-app.nix { inherit pkgs; };
        fluentbit = import ./nix/fluentbit.nix { inherit pkgs; };
        containers = import ./nix/containers.nix { inherit pkgs goApp fluentbit; };

      in {
        # Packages
        packages = {
          # Go application
          loggen = goApp.package;

          # FluentBit
          fluentbit = fluentbit.package;

          # OCI container images
          loggen-image = containers.loggenImage;
          fluentbit-image = containers.fluentbitImage;
          clickhouse-image = containers.clickhouseImage;
          hyperdx-image = containers.hyperdxImage;

          # All images as a bundle
          all-images = containers.allImages;

          # Default package
          default = goApp.package;
        };

        # Development shell
        devShells.default = import ./nix/devshell.nix { inherit pkgs; };

        # Apps for running
        apps = {
          loggen = {
            type = "app";
            program = "${goApp.package}/bin/loggen";
          };

          # Run all tests
          test = {
            type = "app";
            program = toString (pkgs.writeShellScript "test" ''
              cd ${self}
              ${pkgs.go}/bin/go test -v ./...
            '');
          };

          # Run race tests
          test-race = {
            type = "app";
            program = toString (pkgs.writeShellScript "test-race" ''
              cd ${self}
              ${pkgs.go}/bin/go test -race -v ./...
            '');
          };

          # Load images into docker
          load-images = {
            type = "app";
            program = "${containers.loadScript}";
          };
        };

        # NixOS configurations
        nixosConfigurations.microvm = import ./nix/microvm.nix {
          inherit pkgs microvm containers;
        };

        # Checks
        checks = {
          go-test = goApp.testDerivation;
          go-lint = goApp.lintDerivation;
        };
      }
    );
}
```

**Directory Structure:**

```
nix/
├── go-app.nix          # Go application derivation
├── fluentbit.nix       # FluentBit from source
├── containers.nix      # OCI container images
├── devshell.nix        # Development environment
├── microvm.nix         # MicroVM configuration
└── kubernetes/         # K8s manifests as Nix
    ├── namespace.nix
    ├── go-app.nix
    ├── fluentbit.nix
    ├── clickhouse.nix
    └── hyperdx.nix
```

### 4.2 Go Package Derivation

**File:** `nix/go-app.nix`

```nix
{ pkgs }:

let
  version = "0.1.0";

  # Main package derivation
  package = pkgs.buildGoModule {
    pname = "loggen";
    inherit version;

    src = pkgs.lib.cleanSource ./..;

    vendorHash = null;  # Will be set after first build
    # vendorHash = "sha256-XXXX...";

    # Build flags
    ldflags = [
      "-s" "-w"
      "-X main.version=${version}"
    ];

    # Ensure reproducible builds
    CGO_ENABLED = 0;

    meta = with pkgs.lib; {
      description = "Log generator for OpenTelemetry pipeline demo";
      homepage = "https://github.com/example/loggen";
      license = licenses.mit;
      maintainers = [];
    };
  };

  # Test derivation (for CI checks)
  testDerivation = pkgs.runCommand "loggen-test" {
    buildInputs = [ pkgs.go ];
    src = pkgs.lib.cleanSource ./..;
  } ''
    export HOME=$TMPDIR
    export GOCACHE=$TMPDIR/go-cache
    cd $src
    go test -v ./...
    touch $out
  '';

  # Lint derivation
  lintDerivation = pkgs.runCommand "loggen-lint" {
    buildInputs = [ pkgs.go pkgs.golangci-lint ];
    src = pkgs.lib.cleanSource ./..;
  } ''
    export HOME=$TMPDIR
    export GOCACHE=$TMPDIR/go-cache
    export GOLANGCI_LINT_CACHE=$TMPDIR/lint-cache
    cd $src
    golangci-lint run ./...
    touch $out
  '';

  # Race test derivation
  raceTestDerivation = pkgs.runCommand "loggen-race-test" {
    buildInputs = [ pkgs.go ];
    src = pkgs.lib.cleanSource ./..;
  } ''
    export HOME=$TMPDIR
    export GOCACHE=$TMPDIR/go-cache
    cd $src
    CGO_ENABLED=1 go test -race -v ./...
    touch $out
  '';

in {
  inherit package testDerivation lintDerivation raceTestDerivation;
}
```

### 4.3 FluentBit Derivation

**File:** `nix/fluentbit.nix`

```nix
{ pkgs }:

let
  version = "3.2.2";

  # Fetch from GitHub
  src = pkgs.fetchFromGitHub {
    owner = "fluent";
    repo = "fluent-bit";
    rev = "v${version}";
    sha256 = "sha256-XXXX...";  # Will be computed
    fetchSubmodules = true;
  };

  package = pkgs.stdenv.mkDerivation {
    pname = "fluent-bit";
    inherit version src;

    nativeBuildInputs = with pkgs; [
      cmake
      ninja
      pkg-config
      flex
      bison
    ];

    buildInputs = with pkgs; [
      openssl
      libyaml
      zlib
      systemd
      postgresql
      # Lua for our transformation scripts
      lua5_4
    ];

    cmakeFlags = [
      "-DFLB_RELEASE=On"
      "-DFLB_TLS=On"
      "-DFLB_HTTP_SERVER=On"
      "-DFLB_OUT_KAFKA=Off"
      "-DFLB_SHARED_LIB=Off"
      "-DFLB_EXAMPLES=Off"
      "-DFLB_LUAJIT=Off"
      "-DFLB_FILTER_LUA=On"
      # Enable OTel support
      "-DFLB_OUT_OPENTELEMETRY=On"
      # Disable features we don't need
      "-DFLB_IN_SYSTEMD=Off"
      "-DFLB_OUT_PGSQL=Off"
    ];

    # Install configuration files
    postInstall = ''
      mkdir -p $out/etc/fluent-bit
      cp -r ${./fluentbit-config}/* $out/etc/fluent-bit/
    '';

    meta = with pkgs.lib; {
      description = "Fast and lightweight logs and metrics processor";
      homepage = "https://fluentbit.io/";
      license = licenses.asl20;
    };
  };

  # Configuration files
  configDir = pkgs.runCommand "fluentbit-config" {} ''
    mkdir -p $out

    # Main config
    cat > $out/fluent-bit.conf << 'EOF'
    [SERVICE]
        Flush        1
        Log_Level    info
        HTTP_Server  On
        HTTP_Listen  0.0.0.0
        HTTP_Port    2020
        Health_Check On
        HC_Errors_Count 5
        HC_Retry_Failure_Count 5
        HC_Period    5

    @INCLUDE inputs.conf
    @INCLUDE filters.conf
    @INCLUDE outputs.conf
    EOF

    # Inputs config
    cat > $out/inputs.conf << 'EOF'
    [INPUT]
        Name              tail
        Tag               kube.*
        Path              /var/log/containers/loggen-*.log
        Parser            docker
        Refresh_Interval  5
        Mem_Buf_Limit     5MB
        Skip_Long_Lines   On
    EOF

    # Filters config
    cat > $out/filters.conf << 'EOF'
    [FILTER]
        Name          parser
        Match         kube.*
        Key_Name      log
        Parser        json
        Reserve_Data  On

    [FILTER]
        Name          lua
        Match         kube.*
        script        /etc/fluent-bit/lua/transform.lua
        call          transform_to_otel
    EOF

    # Outputs config
    cat > $out/outputs.conf << 'EOF'
    [OUTPUT]
        Name          http
        Match         *
        Host          clickhouse.otel-demo.svc.cluster.local
        Port          8123
        URI           /?query=INSERT%20INTO%20otel_logs%20FORMAT%20JSONEachRow
        Format        json
        Json_Date_Key false
        Retry_Limit   5
    EOF

    # Parsers
    cat > $out/parsers.conf << 'EOF'
    [PARSER]
        Name        docker
        Format      json
        Time_Key    time
        Time_Format %Y-%m-%dT%H:%M:%S.%L
        Time_Keep   On

    [PARSER]
        Name        json
        Format      json
        Time_Key    ts
        Time_Format %s.%L
    EOF

    # Lua transformation script
    mkdir -p $out/lua
    cat > $out/lua/transform.lua << 'EOF'
    ${builtins.readFile ./lua/transform.lua}
    EOF
  '';

in {
  inherit package configDir;
}
```

### 4.4 ClickHouse Derivation

**File:** `nix/clickhouse.nix`

```nix
{ pkgs }:

# Use the existing nixpkgs clickhouse package
let
  clickhouse = pkgs.clickhouse;

  # Custom configuration
  configDir = pkgs.runCommand "clickhouse-config" {} ''
    mkdir -p $out

    # Server config
    cat > $out/config.xml << 'EOF'
    <?xml version="1.0"?>
    <clickhouse>
        <logger>
            <level>information</level>
            <console>1</console>
        </logger>

        <http_port>8123</http_port>
        <tcp_port>9000</tcp_port>
        <interserver_http_port>9009</interserver_http_port>

        <listen_host>0.0.0.0</listen_host>

        <path>/var/lib/clickhouse/</path>
        <tmp_path>/var/lib/clickhouse/tmp/</tmp_path>

        <users_config>users.xml</users_config>

        <default_database>default</default_database>

        <mlock_executable>false</mlock_executable>
    </clickhouse>
    EOF

    # Users config
    cat > $out/users.xml << 'EOF'
    <?xml version="1.0"?>
    <clickhouse>
        <users>
            <default>
                <password></password>
                <networks>
                    <ip>::/0</ip>
                </networks>
                <profile>default</profile>
                <quota>default</quota>
                <access_management>1</access_management>
            </default>
        </users>
        <profiles>
            <default>
                <max_memory_usage>10000000000</max_memory_usage>
            </default>
        </profiles>
        <quotas>
            <default>
                <interval>
                    <duration>3600</duration>
                    <queries>0</queries>
                    <errors>0</errors>
                    <result_rows>0</result_rows>
                    <read_rows>0</read_rows>
                    <execution_time>0</execution_time>
                </interval>
            </default>
        </quotas>
    </clickhouse>
    EOF
  '';

  # Init script for creating the OTel logs table
  initScript = pkgs.writeText "init.sql" ''
    -- HyperDX compatible OTel logs schema
    CREATE TABLE IF NOT EXISTS otel_logs (
        Timestamp DateTime64(9) CODEC(Delta, ZSTD(1)),
        TraceId String CODEC(ZSTD(1)),
        SpanId String CODEC(ZSTD(1)),
        TraceFlags UInt32 CODEC(ZSTD(1)),
        SeverityText LowCardinality(String) CODEC(ZSTD(1)),
        SeverityNumber Int32 CODEC(ZSTD(1)),
        ServiceName LowCardinality(String) CODEC(ZSTD(1)),
        Body String CODEC(ZSTD(1)),
        ResourceSchemaUrl String CODEC(ZSTD(1)),
        ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        ScopeSchemaUrl String CODEC(ZSTD(1)),
        ScopeName String CODEC(ZSTD(1)),
        ScopeVersion String CODEC(ZSTD(1)),
        ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),
        LogAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),

        -- Custom fields for our demo
        RandomNumber Int32 CODEC(ZSTD(1)),
        RandomString LowCardinality(String) CODEC(ZSTD(1)),
        Count UInt64 CODEC(Delta, ZSTD(1)),

        INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
        INDEX idx_severity SeverityText TYPE set(25) GRANULARITY 1,
        INDEX idx_service ServiceName TYPE set(100) GRANULARITY 1,
        INDEX idx_random_number RandomNumber TYPE minmax GRANULARITY 1,
        INDEX idx_random_string RandomString TYPE set(10) GRANULARITY 1,
        INDEX idx_body Body TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1
    )
    ENGINE = MergeTree()
    PARTITION BY toDate(Timestamp)
    ORDER BY (ServiceName, Timestamp)
    TTL toDateTime(Timestamp) + INTERVAL 7 DAY
    SETTINGS index_granularity = 8192, ttl_only_drop_parts = 1;
  '';

in {
  package = clickhouse;
  inherit configDir initScript;
}
```

### 4.5 HyperDX Derivation

**File:** `nix/hyperdx.nix`

```nix
{ pkgs }:

let
  version = "2.0.0";

  # HyperDX is a complex Node.js application
  # We'll build it using buildNpmPackage

  src = pkgs.fetchFromGitHub {
    owner = "hyperdxio";
    repo = "hyperdx";
    rev = "v${version}";
    sha256 = "sha256-XXXX...";  # Will be computed
  };

  # Build the frontend (Next.js app)
  frontend = pkgs.buildNpmPackage {
    pname = "hyperdx-frontend";
    inherit version src;

    sourceRoot = "source/packages/app";

    npmDepsHash = "sha256-XXXX...";

    buildPhase = ''
      runHook preBuild
      npm run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r .next/standalone/* $out/
      cp -r .next/static $out/.next/
      cp -r public $out/
      runHook postInstall
    '';
  };

  # Build the API (Express.js)
  api = pkgs.buildNpmPackage {
    pname = "hyperdx-api";
    inherit version src;

    sourceRoot = "source/packages/api";

    npmDepsHash = "sha256-XXXX...";

    buildPhase = ''
      runHook preBuild
      npm run build
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r dist/* $out/
      cp package.json $out/
      cp -r node_modules $out/
      runHook postInstall
    '';
  };

  # Configuration for connecting to ClickHouse
  configFile = pkgs.writeText "hyperdx-config.env" ''
    CLICKHOUSE_HOST=clickhouse.otel-demo.svc.cluster.local
    CLICKHOUSE_PORT=8123
    CLICKHOUSE_USER=default
    CLICKHOUSE_PASSWORD=

    NEXT_PUBLIC_API_URL=http://localhost:8000
    PORT=8000
    FRONTEND_PORT=8080

    # Disable auth for demo
    HYPERDX_AUTH_DISABLED=true
  '';

in {
  inherit frontend api configFile;

  # Combined package
  package = pkgs.symlinkJoin {
    name = "hyperdx-${version}";
    paths = [ frontend api ];
  };
}
```

### 4.6 Development Shell

**File:** `nix/devshell.nix`

```nix
{ pkgs }:

pkgs.mkShell {
  name = "clickhouse-otel-dev";

  buildInputs = with pkgs; [
    # Go development
    go_1_26
    gopls
    golangci-lint
    delve

    # Nix tools
    nil  # Nix LSP
    nixpkgs-fmt

    # Kubernetes tools
    kubectl
    minikube
    kubernetes-helm
    k9s

    # Container tools
    docker
    docker-compose
    skopeo

    # Database tools
    clickhouse  # CLI client

    # General utilities
    jq
    yq-go
    curl
    httpie

    # Documentation
    mdbook
  ];

  shellHook = ''
    echo "ClickHouse OTel Pipeline Development Environment"
    echo ""
    echo "Available commands:"
    echo "  nix build .#loggen         - Build Go application"
    echo "  nix build .#loggen-image   - Build Go container"
    echo "  nix run .#test             - Run Go tests"
    echo "  nix run .#test-race        - Run Go race tests"
    echo "  nix run .#load-images      - Load images into Docker"
    echo "  nix build .#all-images     - Build all container images"
    echo ""

    # Set Go environment
    export GOPATH=$HOME/go
    export PATH=$GOPATH/bin:$PATH

    # Enable Nix flakes
    export NIX_CONFIG="experimental-features = nix-command flakes"
  '';

  # Environment variables for development
  LOGGEN_MAX_NUMBER = "100";
  LOGGEN_NUM_STRINGS = "10";
  LOGGEN_SLEEP_DURATION = "5s";
}
```

---

## 5. Container Design

### 5.1 Container Philosophy

**Principles:**

1. **Self-contained**: No `/nix/store` bind mounts; all dependencies bundled
2. **Minimal**: Only include what's needed to run
3. **Reproducible**: Built deterministically via Nix
4. **OCI-compliant**: Works with Docker, containerd, podman

**Base Image Strategy:**

| Container | Base | Rationale |
|-----------|------|-----------|
| loggen | scratch | Static Go binary, no runtime needed |
| fluentbit | distroless/cc | Needs libc for plugins |
| clickhouse | distroless/cc | C++ binary with libc deps |
| hyperdx | node:alpine | Node.js runtime required |

### 5.2 Go Application Container

**File:** `nix/containers.nix` (partial)

```nix
{ pkgs, goApp, ... }:

let
  loggenImage = pkgs.dockerTools.buildImage {
    name = "loggen";
    tag = "latest";

    # Use scratch as base (empty)
    fromImage = null;

    # Copy the statically-linked binary
    copyToRoot = pkgs.buildEnv {
      name = "loggen-root";
      paths = [ goApp.package ];
      pathsToLink = [ "/bin" ];
    };

    config = {
      Entrypoint = [ "/bin/loggen" ];

      # Default environment variables
      Env = [
        "LOGGEN_MAX_NUMBER=100"
        "LOGGEN_NUM_STRINGS=10"
        "LOGGEN_SLEEP_DURATION=5s"
        "LOGGEN_HEALTH_PORT=8081"
      ];

      ExposedPorts = {
        "8081/tcp" = {};
      };

      Labels = {
        "org.opencontainers.image.title" = "loggen";
        "org.opencontainers.image.description" = "Log generator for OTel pipeline demo";
        "org.opencontainers.image.source" = "https://github.com/example/loggen";
      };
    };
  };

in { inherit loggenImage; }
```

**Image Details:**

```
REPOSITORY   TAG       SIZE
loggen       latest    ~5MB
```

**Usage:**
```bash
docker run -e LOGGEN_MAX_NUMBER=50 -e LOGGEN_SLEEP_DURATION=1s loggen:latest
```

### 5.3 FluentBit Container

```nix
fluentbitImage = pkgs.dockerTools.buildImage {
  name = "fluentbit";
  tag = "latest";

  # Use distroless as base for libc
  fromImage = pkgs.dockerTools.pullImage {
    imageName = "gcr.io/distroless/cc-debian12";
    imageDigest = "sha256:XXXX...";
    sha256 = "sha256-XXXX...";
  };

  copyToRoot = pkgs.buildEnv {
    name = "fluentbit-root";
    paths = [
      fluentbit.package
      fluentbit.configDir
    ];
    pathsToLink = [ "/bin" "/etc" ];
  };

  config = {
    Entrypoint = [ "/bin/fluent-bit" ];
    Cmd = [ "-c" "/etc/fluent-bit/fluent-bit.conf" ];

    ExposedPorts = {
      "2020/tcp" = {};  # HTTP server / metrics
      "2021/tcp" = {};  # Health check
    };

    Labels = {
      "org.opencontainers.image.title" = "fluent-bit";
      "org.opencontainers.image.description" = "FluentBit with OTel transformation";
    };
  };

  # Add Lua script directory
  extraCommands = ''
    mkdir -p etc/fluent-bit/lua
  '';
};
```

**Image Details:**

```
REPOSITORY   TAG       SIZE
fluentbit    latest    ~50MB
```

### 5.4 ClickHouse Container

```nix
clickhouseImage = pkgs.dockerTools.buildImage {
  name = "clickhouse";
  tag = "latest";

  fromImage = pkgs.dockerTools.pullImage {
    imageName = "gcr.io/distroless/cc-debian12";
    imageDigest = "sha256:XXXX...";
    sha256 = "sha256-XXXX...";
  };

  copyToRoot = pkgs.buildEnv {
    name = "clickhouse-root";
    paths = [
      pkgs.clickhouse
      clickhouse.configDir
    ];
    pathsToLink = [ "/bin" "/etc" ];
  };

  runAsRoot = ''
    #!${pkgs.runtimeShell}
    mkdir -p /var/lib/clickhouse
    mkdir -p /var/log/clickhouse-server
  '';

  config = {
    Entrypoint = [ "/bin/clickhouse-server" ];
    Cmd = [ "--config-file=/etc/clickhouse-server/config.xml" ];

    Env = [
      "CLICKHOUSE_DB=default"
    ];

    ExposedPorts = {
      "8123/tcp" = {};  # HTTP interface
      "9000/tcp" = {};  # Native protocol
      "9009/tcp" = {};  # Interserver
    };

    Volumes = {
      "/var/lib/clickhouse" = {};
    };
  };
};
```

**Image Details:**

```
REPOSITORY    TAG       SIZE
clickhouse    latest    ~400MB
```

### 5.5 HyperDX Container

```nix
hyperdxImage = pkgs.dockerTools.buildImage {
  name = "hyperdx";
  tag = "latest";

  fromImage = pkgs.dockerTools.pullImage {
    imageName = "node";
    imageDigest = "sha256:XXXX...";  # node:22-alpine
    sha256 = "sha256-XXXX...";
  };

  copyToRoot = pkgs.buildEnv {
    name = "hyperdx-root";
    paths = [
      hyperdx.package
      hyperdx.configFile
    ];
  };

  config = {
    WorkingDir = "/app";

    Entrypoint = [ "/bin/sh" "-c" ];
    Cmd = [ "node /app/api/server.js & node /app/frontend/server.js" ];

    Env = [
      "NODE_ENV=production"
      "CLICKHOUSE_HOST=clickhouse"
      "CLICKHOUSE_PORT=8123"
    ];

    ExposedPorts = {
      "8000/tcp" = {};  # API
      "8080/tcp" = {};  # Frontend
    };
  };
};
```

### 5.6 Container Registry Strategy

**Local Development:**
```nix
# Load all images into local Docker
loadScript = pkgs.writeShellScript "load-images" ''
  echo "Loading container images into Docker..."

  ${pkgs.docker}/bin/docker load < ${loggenImage}
  ${pkgs.docker}/bin/docker load < ${fluentbitImage}
  ${pkgs.docker}/bin/docker load < ${clickhouseImage}
  ${pkgs.docker}/bin/docker load < ${hyperdxImage}

  echo "Images loaded:"
  ${pkgs.docker}/bin/docker images | grep -E "(loggen|fluentbit|clickhouse|hyperdx)"
'';

# Bundle all images
allImages = pkgs.runCommand "all-images" {} ''
  mkdir -p $out
  cp ${loggenImage} $out/loggen.tar.gz
  cp ${fluentbitImage} $out/fluentbit.tar.gz
  cp ${clickhouseImage} $out/clickhouse.tar.gz
  cp ${hyperdxImage} $out/hyperdx.tar.gz
'';
```

---

## 6. FluentBit Pipeline Design

### 6.1 Log Collection

**Input Configuration:**

```ini
[INPUT]
    Name              tail
    Tag               kube.loggen.*
    Path              /var/log/containers/loggen-*.log
    Parser            docker
    Refresh_Interval  5
    Rotate_Wait       30
    Mem_Buf_Limit     10MB
    Skip_Long_Lines   On
    DB                /var/lib/fluent-bit/tail.db
    DB.Sync           Normal
```

**Kubernetes Log Format:**
```json
{
  "log": "{\"level\":\"info\",\"ts\":1708272000.123,\"msg\":\"tick\",\"count\":1,\"random_number\":42,\"random_string\":\"gamma\"}",
  "stream": "stdout",
  "time": "2024-02-18T12:00:00.123456789Z"
}
```

### 6.2 Lua Transformation Script

**File:** `nix/lua/transform.lua`

```lua
-- transform.lua
-- Transforms FluentBit records to OTel log format for ClickHouse

-- Severity mapping (zap levels to OTel severity numbers)
local severity_map = {
    debug = 5,
    info = 9,
    warn = 13,
    warning = 13,
    error = 17,
    dpanic = 21,
    panic = 21,
    fatal = 21
}

local severity_text_map = {
    debug = "DEBUG",
    info = "INFO",
    warn = "WARN",
    warning = "WARN",
    error = "ERROR",
    dpanic = "FATAL",
    panic = "FATAL",
    fatal = "FATAL"
}

-- Convert zap timestamp (float seconds) to nanoseconds
local function to_nano(ts)
    if type(ts) == "number" then
        return math.floor(ts * 1e9)
    end
    return 0
end

-- Extract Kubernetes metadata from tag
local function parse_k8s_tag(tag)
    -- Tag format: kube.loggen.<namespace>_<pod>_<container>
    local namespace, pod, container = string.match(tag, "kube%.loggen%.([^_]+)_([^_]+)_(.+)")
    return namespace or "unknown", pod or "unknown", container or "unknown"
end

-- Main transformation function
function transform_to_otel(tag, timestamp, record)
    local namespace, pod, container = parse_k8s_tag(tag)

    -- Parse the inner JSON log if needed
    local log_data = record
    if type(record.log) == "string" then
        -- Kubernetes wraps logs, need to parse inner JSON
        local ok, parsed = pcall(function()
            return require("cjson").decode(record.log)
        end)
        if ok then
            log_data = parsed
        end
    end

    -- Build OTel log record
    local otel_record = {
        -- Timestamp in DateTime64(9) format
        Timestamp = to_nano(log_data.ts or timestamp),

        -- Trace context (empty for this demo)
        TraceId = "",
        SpanId = "",
        TraceFlags = 0,

        -- Severity
        SeverityText = severity_text_map[log_data.level] or "INFO",
        SeverityNumber = severity_map[log_data.level] or 9,

        -- Service identification
        ServiceName = "loggen",

        -- Log body
        Body = log_data.msg or "",

        -- Resource attributes
        ResourceSchemaUrl = "",
        ResourceAttributes = {
            ["service.name"] = "loggen",
            ["service.version"] = "1.0.0",
            ["k8s.namespace.name"] = namespace,
            ["k8s.pod.name"] = pod,
            ["k8s.container.name"] = container
        },

        -- Scope attributes
        ScopeSchemaUrl = "",
        ScopeName = "loggen",
        ScopeVersion = "1.0.0",
        ScopeAttributes = {},

        -- Log attributes (custom fields)
        LogAttributes = {
            ["caller"] = log_data.caller or "",
            ["count"] = tostring(log_data.count or 0)
        },

        -- Custom indexed fields for our demo queries
        RandomNumber = log_data.random_number or 0,
        RandomString = log_data.random_string or "",
        Count = log_data.count or 0
    }

    return 1, timestamp, otel_record
end
```

### 6.3 ClickHouse Output

**Output Configuration:**

```ini
[OUTPUT]
    Name                 http
    Match                kube.loggen.*
    Host                 clickhouse.otel-demo.svc.cluster.local
    Port                 8123
    URI                  /?query=INSERT%20INTO%20otel_logs%20FORMAT%20JSONEachRow
    Format               json_lines
    Json_Date_Key        false
    Json_Date_Format     epoch
    Retry_Limit          5
    Workers              2

    # TLS settings (if needed)
    tls                  Off

    # Headers
    Header               Content-Type application/json
```

---

## 7. ClickHouse Schema Design

### 7.1 HyperDX Native Schema

**Table: `otel_logs`**

```sql
CREATE TABLE otel_logs (
    -- Timestamp with nanosecond precision
    Timestamp DateTime64(9) CODEC(Delta, ZSTD(1)),

    -- Trace context
    TraceId String CODEC(ZSTD(1)),
    SpanId String CODEC(ZSTD(1)),
    TraceFlags UInt32 CODEC(ZSTD(1)),

    -- Severity
    SeverityText LowCardinality(String) CODEC(ZSTD(1)),
    SeverityNumber Int32 CODEC(ZSTD(1)),

    -- Service
    ServiceName LowCardinality(String) CODEC(ZSTD(1)),

    -- Body
    Body String CODEC(ZSTD(1)),

    -- Resource
    ResourceSchemaUrl String CODEC(ZSTD(1)),
    ResourceAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- Scope
    ScopeSchemaUrl String CODEC(ZSTD(1)),
    ScopeName String CODEC(ZSTD(1)),
    ScopeVersion String CODEC(ZSTD(1)),
    ScopeAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- Log attributes
    LogAttributes Map(LowCardinality(String), String) CODEC(ZSTD(1)),

    -- Custom indexed fields
    RandomNumber Int32 CODEC(ZSTD(1)),
    RandomString LowCardinality(String) CODEC(ZSTD(1)),
    Count UInt64 CODEC(Delta, ZSTD(1)),

    -- Indexes
    INDEX idx_trace_id TraceId TYPE bloom_filter(0.001) GRANULARITY 1,
    INDEX idx_severity SeverityText TYPE set(25) GRANULARITY 1,
    INDEX idx_service ServiceName TYPE set(100) GRANULARITY 1,
    INDEX idx_random_number RandomNumber TYPE minmax GRANULARITY 1,
    INDEX idx_random_string RandomString TYPE set(10) GRANULARITY 1,
    INDEX idx_body Body TYPE tokenbf_v1(32768, 3, 0) GRANULARITY 1
)
ENGINE = MergeTree()
PARTITION BY toDate(Timestamp)
ORDER BY (ServiceName, Timestamp)
TTL toDateTime(Timestamp) + INTERVAL 7 DAY
SETTINGS
    index_granularity = 8192,
    ttl_only_drop_parts = 1;
```

### 7.2 Initialization Scripts

**File:** `k8s/clickhouse/init.sql`

```sql
-- Create database
CREATE DATABASE IF NOT EXISTS default;

-- Create OTel logs table
CREATE TABLE IF NOT EXISTS default.otel_logs (...);

-- Create materialized view for aggregations
CREATE MATERIALIZED VIEW IF NOT EXISTS otel_logs_hourly
ENGINE = SummingMergeTree()
PARTITION BY toDate(hour)
ORDER BY (ServiceName, hour, RandomString)
AS SELECT
    toStartOfHour(Timestamp) AS hour,
    ServiceName,
    RandomString,
    count() AS log_count,
    avg(RandomNumber) AS avg_random_number,
    min(RandomNumber) AS min_random_number,
    max(RandomNumber) AS max_random_number
FROM otel_logs
GROUP BY hour, ServiceName, RandomString;

-- Example queries for demo
-- Count logs by random_string
-- SELECT RandomString, count() FROM otel_logs GROUP BY RandomString;

-- Find logs with random_number = 10
-- SELECT * FROM otel_logs WHERE RandomNumber = 10 LIMIT 100;

-- Time series of log counts
-- SELECT toStartOfMinute(Timestamp) AS minute, count()
-- FROM otel_logs
-- GROUP BY minute
-- ORDER BY minute;
```

---

## 8. MicroVM Design

### 8.1 VM Configuration

**File:** `nix/microvm.nix`

```nix
{ pkgs, microvm, containers }:

{
  microvm = {
    # Hypervisor selection
    hypervisor = "qemu";

    # Resource allocation
    mem = 8192;  # 8GB RAM
    vcpu = 4;    # 4 CPUs

    # Storage
    volumes = [
      {
        mountPoint = "/var";
        image = "var.img";
        size = 20480;  # 20GB
      }
    ];

    # Shared directories (for development)
    shares = [
      {
        source = "/nix/store";
        mountPoint = "/nix/.ro-store";
        tag = "ro-store";
        proto = "virtiofs";
      }
    ];

    # Network interfaces
    interfaces = [
      {
        type = "user";
        id = "eth0";
        mac = "02:00:00:00:00:01";
      }
    ];

    # Port forwards (user-mode networking)
    # Using high non-standard ports to avoid collisions with host services
    forwardPorts = [
      { from = "host"; host.port = 22022; guest.port = 22; }    # SSH
      { from = "host"; host.port = 28080; guest.port = 8080; }  # HyperDX UI
      { from = "host"; host.port = 28123; guest.port = 8123; }  # ClickHouse HTTP
      { from = "host"; host.port = 29000; guest.port = 9000; }  # ClickHouse Native
      { from = "host"; host.port = 28000; guest.port = 8000; }  # HyperDX API
      { from = "host"; host.port = 22020; guest.port = 2020; }  # FluentBit Metrics
    ];

    # Socket for virtiofs
    socket = "control.sock";
  };

  # NixOS configuration inside the VM
  nixosConfiguration = {
    imports = [ microvm.nixosModules.microvm ];

    # System basics
    system.stateVersion = "24.05";

    networking = {
      hostName = "otel-demo";
      firewall.enable = false;
    };

    # Enable Docker for Minikube
    virtualisation.docker = {
      enable = true;
      autoPrune.enable = true;
    };

    # Install Minikube
    environment.systemPackages = with pkgs; [
      minikube
      kubectl
      docker
      # Container images
      containers.allImages
    ];

    # Service to start Minikube
    systemd.services.minikube = {
      description = "Minikube Kubernetes Cluster";
      after = [ "docker.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        ExecStart = "${pkgs.minikube}/bin/minikube start --driver=docker --cpus=3 --memory=6g";
        ExecStop = "${pkgs.minikube}/bin/minikube stop";
      };
    };

    # Service to load container images
    systemd.services.load-images = {
      description = "Load OCI images into Minikube";
      after = [ "minikube.service" ];
      wantedBy = [ "multi-user.target" ];

      script = ''
        ${pkgs.minikube}/bin/minikube image load ${containers.loggenImage}
        ${pkgs.minikube}/bin/minikube image load ${containers.fluentbitImage}
        ${pkgs.minikube}/bin/minikube image load ${containers.clickhouseImage}
        ${pkgs.minikube}/bin/minikube image load ${containers.hyperdxImage}
      '';
    };

    # User configuration
    users.users.demo = {
      isNormalUser = true;
      extraGroups = [ "docker" ];
    };
  };
}
```

### 8.2 Network Configuration

**Port Allocation Strategy:**

All host-side forwarded ports use a `2XXXX` prefix to avoid collisions with common services on the host system. Guest ports remain at their standard values for compatibility.

**Port Forwarding Table:**

| Host Port | Guest Port | Service | Protocol |
|-----------|------------|---------|----------|
| 22022 | 22 | SSH | TCP |
| 28080 | 8080 | HyperDX UI | HTTP |
| 28000 | 8000 | HyperDX API | HTTP |
| 28123 | 8123 | ClickHouse HTTP | HTTP |
| 29000 | 9000 | ClickHouse Native | TCP |
| 22020 | 2020 | FluentBit Metrics | HTTP |

**Access from Host:**
```bash
# SSH into MicroVM
ssh -p 22022 demo@localhost

# HyperDX UI (browser)
xdg-open http://localhost:28080

# ClickHouse HTTP API
curl http://localhost:28123

# ClickHouse native client
clickhouse-client --host localhost --port 29000

# FluentBit metrics
curl http://localhost:22020/api/v1/metrics
```

### 8.3 Container Image Loading

**Script:** `load-images.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

echo "Loading container images into Minikube..."

# Wait for Minikube to be ready
minikube status || {
    echo "Minikube is not running. Starting..."
    minikube start --driver=docker --cpus=3 --memory=6g
}

# Load images
for image in loggen fluentbit clickhouse hyperdx; do
    echo "Loading ${image}..."
    minikube image load /images/${image}.tar.gz
done

echo "Verifying images..."
minikube image ls | grep -E "(loggen|fluentbit|clickhouse|hyperdx)"

echo "Done!"
```

### 8.4 Minikube Integration

**Minikube Configuration:**

```yaml
# minikube-config.yaml
apiVersion: minikube.k8s.io/v1beta1
kind: ClusterConfig
metadata:
  name: otel-demo
driver: docker
cpus: 3
memory: 6144
nodes:
  - role: control-plane
addons:
  metrics-server: true
  dashboard: false
```

---

## 9. Kubernetes Manifests

### 9.1 Namespace Organization

```yaml
# k8s/namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: otel-demo
  labels:
    app.kubernetes.io/name: otel-demo
    app.kubernetes.io/component: infrastructure
```

### 9.2 Go Application Deployment

```yaml
# k8s/loggen/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loggen
  namespace: otel-demo
  labels:
    app: loggen
spec:
  replicas: 1
  selector:
    matchLabels:
      app: loggen
  template:
    metadata:
      labels:
        app: loggen
    spec:
      containers:
        - name: loggen
          image: loggen:latest
          imagePullPolicy: Never  # Use local image
          env:
            - name: LOGGEN_MAX_NUMBER
              value: "100"
            - name: LOGGEN_NUM_STRINGS
              value: "10"
            - name: LOGGEN_SLEEP_DURATION
              value: "5s"
            - name: LOGGEN_HEALTH_PORT
              value: "8081"
          ports:
            - name: health
              containerPort: 8081
              protocol: TCP
          livenessProbe:
            httpGet:
              path: /health
              port: health
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ready
              port: health
            initialDelaySeconds: 5
            periodSeconds: 5
          resources:
            requests:
              memory: "32Mi"
              cpu: "10m"
            limits:
              memory: "64Mi"
              cpu: "100m"
```

### 9.3 FluentBit DaemonSet

```yaml
# k8s/fluentbit/daemonset.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: fluentbit
  namespace: otel-demo
  labels:
    app: fluentbit
spec:
  selector:
    matchLabels:
      app: fluentbit
  template:
    metadata:
      labels:
        app: fluentbit
    spec:
      serviceAccountName: fluentbit
      containers:
        - name: fluentbit
          image: fluentbit:latest
          imagePullPolicy: Never
          ports:
            - name: metrics
              containerPort: 2020
              protocol: TCP
          volumeMounts:
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: varlibdockercontainers
              mountPath: /var/lib/docker/containers
              readOnly: true
            - name: config
              mountPath: /etc/fluent-bit
          resources:
            requests:
              memory: "64Mi"
              cpu: "50m"
            limits:
              memory: "128Mi"
              cpu: "200m"
      volumes:
        - name: varlog
          hostPath:
            path: /var/log
        - name: varlibdockercontainers
          hostPath:
            path: /var/lib/docker/containers
        - name: config
          configMap:
            name: fluentbit-config
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: fluentbit
  namespace: otel-demo
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: fluentbit
rules:
  - apiGroups: [""]
    resources: ["pods", "namespaces"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: fluentbit
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: fluentbit
subjects:
  - kind: ServiceAccount
    name: fluentbit
    namespace: otel-demo
```

### 9.4 ClickHouse StatefulSet

```yaml
# k8s/clickhouse/statefulset.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: clickhouse
  namespace: otel-demo
spec:
  serviceName: clickhouse
  replicas: 1
  selector:
    matchLabels:
      app: clickhouse
  template:
    metadata:
      labels:
        app: clickhouse
    spec:
      containers:
        - name: clickhouse
          image: clickhouse:latest
          imagePullPolicy: Never
          ports:
            - name: http
              containerPort: 8123
            - name: native
              containerPort: 9000
            - name: interserver
              containerPort: 9009
          volumeMounts:
            - name: data
              mountPath: /var/lib/clickhouse
            - name: config
              mountPath: /etc/clickhouse-server
            - name: init
              mountPath: /docker-entrypoint-initdb.d
          resources:
            requests:
              memory: "1Gi"
              cpu: "500m"
            limits:
              memory: "2Gi"
              cpu: "2000m"
          livenessProbe:
            httpGet:
              path: /ping
              port: http
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /ping
              port: http
            initialDelaySeconds: 10
            periodSeconds: 5
      volumes:
        - name: config
          configMap:
            name: clickhouse-config
        - name: init
          configMap:
            name: clickhouse-init
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ["ReadWriteOnce"]
        resources:
          requests:
            storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: clickhouse
  namespace: otel-demo
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 8123
      targetPort: 8123
    - name: native
      port: 9000
      targetPort: 9000
    - name: interserver
      port: 9009
      targetPort: 9009
  selector:
    app: clickhouse
```

### 9.5 HyperDX Deployment

```yaml
# k8s/hyperdx/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hyperdx
  namespace: otel-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hyperdx
  template:
    metadata:
      labels:
        app: hyperdx
    spec:
      containers:
        - name: hyperdx
          image: hyperdx:latest
          imagePullPolicy: Never
          env:
            - name: CLICKHOUSE_HOST
              value: "clickhouse.otel-demo.svc.cluster.local"
            - name: CLICKHOUSE_PORT
              value: "8123"
            - name: CLICKHOUSE_USER
              value: "default"
            - name: CLICKHOUSE_PASSWORD
              value: ""
            - name: HYPERDX_AUTH_DISABLED
              value: "true"
          ports:
            - name: api
              containerPort: 8000
            - name: ui
              containerPort: 8080
          resources:
            requests:
              memory: "512Mi"
              cpu: "250m"
            limits:
              memory: "1Gi"
              cpu: "1000m"
          livenessProbe:
            httpGet:
              path: /health
              port: api
            initialDelaySeconds: 30
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: api
            initialDelaySeconds: 10
            periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: hyperdx
  namespace: otel-demo
spec:
  type: NodePort
  ports:
    - name: api
      port: 8000
      targetPort: 8000
      nodePort: 30800
    - name: ui
      port: 8080
      targetPort: 8080
      nodePort: 30808
  selector:
    app: hyperdx
```

---

## 10. Testing Strategy

### 10.1 Unit Tests

| Component | Test Type | Framework | Coverage |
|-----------|-----------|-----------|----------|
| Go loop | Unit | go test | 90%+ |
| Go random | Unit | go test | 100% |
| Go health | Unit | go test | 85%+ |
| Go config | Unit | go test | 90%+ |
| Lua transform | Unit | busted | 90%+ |

**Run Go Tests:**
```bash
nix run .#test
nix run .#test-race
```

### 10.2 Integration Tests

| Test | Description | Method |
|------|-------------|--------|
| FluentBit → ClickHouse | Verify logs flow | docker-compose |
| Lua transformation | Verify OTel format | mock records |
| ClickHouse schema | Verify queries work | SQL tests |

**Integration Test Script:**

```bash
#!/usr/bin/env bash
# test/integration.sh

# Start test containers
docker-compose -f test/docker-compose.test.yml up -d

# Wait for services
sleep 10

# Generate test logs
docker exec loggen /bin/loggen --sleep-duration=1s &
sleep 30
kill %1

# Verify logs in ClickHouse
count=$(docker exec clickhouse clickhouse-client -q "SELECT count() FROM otel_logs")
if [ "$count" -lt 20 ]; then
    echo "FAIL: Expected at least 20 logs, got $count"
    exit 1
fi

# Verify custom fields
strings=$(docker exec clickhouse clickhouse-client -q \
    "SELECT uniq(RandomString) FROM otel_logs")
if [ "$strings" -lt 5 ]; then
    echo "FAIL: Expected diverse RandomStrings"
    exit 1
fi

echo "PASS: Integration tests succeeded"
```

### 10.3 End-to-End Tests

| Test | Description | Method |
|------|-------------|--------|
| Full pipeline | VM → K8s → all services | MicroVM |
| HyperDX queries | Verify UI queries work | Playwright |
| Aggregations | Verify GROUP BY works | SQL |

---

## 11. Build and Deployment

### 11.1 Build Commands

```bash
# Build Go application
nix build .#loggen

# Build all container images
nix build .#all-images

# Build MicroVM
nix build .#nixosConfigurations.microvm.config.system.build.vm

# Run tests
nix run .#test
nix run .#test-race

# Enter development shell
nix develop

# Load images into Docker
nix run .#load-images
```

### 11.2 Deployment Workflow

```bash
# 1. Build everything
nix build .#all-images

# 2. Start MicroVM
./result/bin/run-otel-demo-vm

# 3. SSH into VM (optional)
ssh -p 22022 demo@localhost

# 4. Verify Minikube is running
kubectl get nodes

# 5. Apply Kubernetes manifests
kubectl apply -f k8s/

# 6. Watch pods come up
kubectl -n otel-demo get pods -w

# 7. Access HyperDX UI
# Open http://localhost:28080 in browser

# 8. Run sample queries
# - Search: random_number:42
# - Aggregate: GROUP BY random_string
```

---

## 12. Appendices

### Appendix A: Directory Structure

```
clickhouse-otel-example/
├── flake.nix                 # Main Nix flake
├── flake.lock                # Locked dependencies
├── DESIGN.md                 # This document
├── README.md                 # Project overview
│
├── cmd/
│   └── loggen/
│       └── main.go           # Application entry point
│
├── internal/
│   ├── config/
│   │   ├── config.go
│   │   └── config_test.go
│   ├── health/
│   │   ├── health.go
│   │   └── health_test.go
│   └── loop/
│       ├── loop.go
│       ├── loop_test.go
│       ├── random.go
│       └── random_test.go
│
├── nix/
│   ├── go-app.nix            # Go derivation
│   ├── fluentbit.nix         # FluentBit derivation
│   ├── clickhouse.nix        # ClickHouse config
│   ├── hyperdx.nix           # HyperDX derivation
│   ├── containers.nix        # OCI image builders
│   ├── devshell.nix          # Development environment
│   ├── microvm.nix           # MicroVM configuration
│   └── lua/
│       └── transform.lua     # FluentBit Lua script
│
├── k8s/
│   ├── namespace.yaml
│   ├── loggen/
│   │   └── deployment.yaml
│   ├── fluentbit/
│   │   ├── daemonset.yaml
│   │   └── configmap.yaml
│   ├── clickhouse/
│   │   ├── statefulset.yaml
│   │   ├── configmap.yaml
│   │   └── init.sql
│   └── hyperdx/
│       └── deployment.yaml
│
├── test/
│   ├── integration.sh
│   └── docker-compose.test.yml
│
├── go.mod
└── go.sum
```

### Appendix B: Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOGGEN_MAX_NUMBER` | `100` | Upper bound for random numbers |
| `LOGGEN_NUM_STRINGS` | `10` | Number of random strings to use |
| `LOGGEN_SLEEP_DURATION` | `5s` | Interval between log emissions |
| `LOGGEN_HEALTH_PORT` | `8081` | Health check server port |

### Appendix C: Port Mappings

**MicroVM Host Forwards:**

| Service | Guest Port | Host Forward | Protocol |
|---------|------------|--------------|----------|
| SSH | 22 | 22022 | TCP |
| HyperDX UI | 8080 | 28080 | HTTP |
| HyperDX API | 8000 | 28000 | HTTP |
| ClickHouse HTTP | 8123 | 28123 | HTTP |
| ClickHouse Native | 9000 | 29000 | TCP |
| FluentBit Metrics | 2020 | 22020 | HTTP |

**Kubernetes Services:**

| Service | Container Port | NodePort | Protocol |
|---------|---------------|----------|----------|
| loggen health | 8081 | - | HTTP |
| fluentbit metrics | 2020 | - | HTTP |
| clickhouse http | 8123 | - | HTTP |
| clickhouse native | 9000 | - | TCP |
| hyperdx api | 8000 | 30800 | HTTP |
| hyperdx ui | 8080 | 30808 | HTTP |

**Port Allocation Strategy:**
- All host-side forwarded ports use a `2XXXX` prefix to avoid collisions
- Guest/container ports remain at standard values for compatibility
- Pattern: `2` + original port (e.g., 22 → 22022, 8080 → 28080, 9000 → 29000)
- NodePorts (30800, 30808) are only used within the VM's Minikube cluster

---

*End of Design Document*
