# ClickHouse OpenTelemetry Pipeline Demo

**Last Updated:** 2026-02-27

A complete demonstration of an OpenTelemetry logs pipeline using Nix for reproducible builds. The pipeline collects JSON logs from a Go application, transforms them to OTel format via FluentBit, stores them in ClickHouse, and visualizes them with HyperDX.

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Loggen    │────▶│  FluentBit  │────▶│ ClickHouse  │◀────│   HyperDX   │
│  (Go App)   │     │  (DaemonSet)│     │ (StatefulSet│     │    (UI)     │
│             │     │  + Lua      │     │             │     │             │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
     JSON logs      Transform to OTel    Store logs         Query & visualize
```

## Table of Contents

- [What's Built](#whats-built)
- [Demo Credentials](#demo-credentials)
- [Quick Start](#quick-start)
- [Docker Compose (Local Development)](#docker-compose-local-development)
- [Configuration](#configuration)
- [Kubernetes Deployment](#kubernetes-deployment)
- [Pipeline Verification](#pipeline-verification)
- [Failure Injection Testing](#failure-injection-testing)
- [MicroVM](#microvm)
- [Development](#development)
- [Technical Notes](#technical-notes)
- [Integration Testing](#integration-testing)

## What's Built

All components are built reproducibly with Nix - no Docker Hub pulls required.

| Component | Description | Image Size* | Status |
|-----------|-------------|-------------|--------|
| **loggen** | Go application generating random JSON logs | 3.3 MB | ✅ Working |
| **fluentbit** | Log collector with Lua OTel transformation | 75 MB | ✅ Working |
| **clickhouse** | Column-oriented database for log storage | 355 MB (293 MB minimal) | ✅ Working |
| **mongodb** | Document database for HyperDX session storage | ~500 MB | ✅ Working |
| **ferretdb** | MongoDB-compatible with SQLite backend | ~50 MB | ⚠️ Limited* |
| **hyperdx** | Observability UI (built from source) | 406 MB | ✅ Working |

*FerretDB lacks TTL index support (`expireAfterSeconds`) required by HyperDX session management.

*Compressed image sizes. Docker reports larger uncompressed sizes when loaded.

## Demo Credentials

A demo user is automatically created when deploying to Kubernetes:

| Field | Value |
|-------|-------|
| **Email** | `demo@example.com` |
| **Password** | `DemoPassword123!` |

The user is created by an init job (`hyperdx-init-user`) that runs after deployment. If you need to reset the credentials, delete the FerretDB PVC and redeploy:

```bash
kubectl -n otel-demo delete pvc data-ferretdb-0
kubectl -n otel-demo delete pod ferretdb-0
kubectl -n otel-demo delete job hyperdx-init-user
kubectl apply -k k8s/
```

## Features

### Go Application (loggen)
- Generates JSON logs with random numbers (0-100) and random strings
- Uses [uber-go/zap](https://github.com/uber-go/zap) for structured logging
- Configurable via CLI flags or environment variables
- Health endpoints: `/health` and `/ready`
- Graceful shutdown on SIGINT/SIGTERM
- Full test coverage including race condition tests

### FluentBit
- DaemonSet deployment for Kubernetes log collection
- Kubernetes filter enriches logs with pod metadata (labels, node name)
- Lua script transforms JSON to OpenTelemetry format with dynamic service names
- Outputs to ClickHouse HTTP interface with async inserts and gzip compression
- 2-second flush interval for batch efficiency

### ClickHouse
- HyperDX-compatible `otel_logs` table schema with ObservedTimestamp
- MATERIALIZED columns for efficient K8s metadata queries (ContainerName, PodName, NamespaceName, NodeName)
- Bloom filter and set indexes for fast filtering
- Persistent storage via StatefulSet

### HyperDX
- Built from source using Nix yarn-berry infrastructure
- Local fonts from nixpkgs (no Google Fonts CDN dependency)
- Next.js standalone output for production deployment

## Quick Start

### Prerequisites
- Nix with flakes enabled
- Docker (for loading images)

### Build Everything

```bash
# Enter development shell
nix develop

# Build all container images
nix build .#all-images

# Or build individually
nix build .#loggen-image
nix build .#fluentbit-image
nix build .#clickhouse-image
nix build .#hyperdx-image
```

### Load Images into Docker

```bash
nix run .#load-images
```

### Run Tests

```bash
# Run Go tests
nix run .#test

# Run race condition tests
nix run .#test-race

# Run all Nix checks
nix flake check
```

### Run Locally

```bash
# Run the loggen application directly
nix run .#loggen -- --max-number 50 --num-strings 5 --sleep-duration 2s

# Or with environment variables
LOGGEN_MAX_NUMBER=50 LOGGEN_NUM_STRINGS=5 nix run .#loggen
```

## Docker Compose (Local Development)

For faster iteration without a MicroVM, use Docker Compose directly on your host. Nix generates the `docker-compose.yaml` with configuration from `nix/ports.nix`.

### Quick Start

```bash
# Start the stack
nix run .#compose-up

# View logs
nix run .#compose-logs

# Check status
nix run .#compose-ps

# Stop the stack
nix run .#compose-down
```

### Access Points

| Service | URL |
|---------|-----|
| **HyperDX UI** | http://localhost:38080 |
| **HyperDX API** | http://localhost:38000 |
| **ClickHouse HTTP** | http://localhost:38123 |
| **ClickHouse Native** | localhost:39000 |
| **MongoDB** | localhost:37017 |

### First-Time Setup

HyperDX runs in local app mode (no login required). After starting the stack, run the setup script to configure the connection, source, and demo dashboard:

```bash
# Automated setup (creates connection, source, and dashboard)
nix run .#compose-setup
```

This creates:
- **Connection:** Default (http://clickhouse:8123)
- **Source:** OTel Logs (default.otel_logs table)
- **Dashboard:** Loggen Metrics with 4 charts:
  - RandomString Distribution (table)
  - RandomNumber Over Time (line chart)
  - Avg RandomNumber by String (table)
  - Log Count Over Time (line chart)

Then open http://localhost:38080 and navigate to **Dashboards** → **Loggen Metrics**.

<details>
<summary>Manual Setup (alternative)</summary>

If you prefer to configure manually:

1. Open http://localhost:38080
2. Go to **Team Settings** → **Connections** → **Add Connection**:
   - **Name:** `Default`
   - **Host:** `http://clickhouse:8123`
   - **Username:** `default`
   - **Password:** (leave empty)
3. Go to **Team Settings** → **Sources** → **Add Source**:
   - **Name:** `OTel Logs`
   - **Connection:** `Default`
   - **Database:** `default`
   - **Table:** `otel_logs`
   - **Timestamp:** `TimestampTime`
   - **Body:** `Body`
   - **Severity:** `SeverityText`
   - **Service Name:** `ServiceName`
4. Navigate to **Search** to view logs

</details>

### Verify Data Flow

```bash
# Check logs in ClickHouse
curl 'http://localhost:38123/?query=SELECT%20count()%20FROM%20otel_logs'

# View recent logs
curl 'http://localhost:38123/?query=SELECT%20*%20FROM%20otel_logs%20ORDER%20BY%20Timestamp%20DESC%20LIMIT%205%20FORMAT%20Pretty'
```

### Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Loggen    │────▶│  FluentBit  │────▶│ ClickHouse  │◀────│   HyperDX   │
│ (container) │     │ (fluentd    │     │ (container) │     │ (container) │
│             │     │  driver)    │     │             │     │             │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
     JSON logs      Transform to OTel    Store logs         Query & visualize
```

### Notes

- Uses official Docker images (ClickHouse, MongoDB, HyperDX) plus Nix-built loggen
- Ports use `3XXXX` prefix to avoid conflicts with local services
- Data persists in Docker volumes (`store_clickhouse-data`, `store_mongodb-data`)
- FluentBit transforms logs via Lua script to OTel format

## Configuration

### Loggen Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `LOGGEN_MAX_NUMBER` | 100 | Maximum random number |
| `LOGGEN_NUM_STRINGS` | 10 | Number of random strings in pool |
| `LOGGEN_SLEEP_DURATION` | 5s | Sleep between log emissions |
| `LOGGEN_HEALTH_PORT` | 8081 | Health endpoint port |

### Port Configuration

All ports are centralized in `nix/ports.nix`:

**Service Ports (inside containers):**
| Service | Port |
|---------|------|
| Loggen Health | 8081 |
| FluentBit Metrics | 2020 |
| ClickHouse HTTP | 8123 |
| ClickHouse Native | 9000 |
| MongoDB | 27017 |
| HyperDX API | 8000 |
| HyperDX App | 8080 |

**Host Forwards (MicroVM → Host):**
| Service | Port |
|---------|------|
| SSH | 22022 |
| FluentBit Metrics | 22020 |
| ClickHouse HTTP | 28123 |
| ClickHouse Native | 29000 |
| MongoDB | 27017 |
| HyperDX API | 28000 |
| HyperDX App | 28080 |

**Docker Compose External Ports:**
| Service | Port |
|---------|------|
| HyperDX App | 38080 |
| HyperDX API | 38000 |
| ClickHouse HTTP | 38123 |
| ClickHouse Native | 39000 |
| MongoDB | 37017 |

## Project Structure

```
clickhouse-otel-example/
├── cmd/loggen/
│   └── main.go                 # Application entry point
├── internal/
│   ├── config/                 # CLI flags + env var configuration
│   ├── health/                 # HTTP health endpoints
│   └── loop/                   # Log generation logic
├── k8s/
│   ├── namespace.yaml          # otel-demo namespace
│   ├── loggen/                 # Loggen deployment
│   ├── fluentbit/              # FluentBit DaemonSet + ConfigMap
│   ├── clickhouse/             # ClickHouse StatefulSet + init SQL
│   ├── mongodb/                # MongoDB StatefulSet (default backend)
│   ├── ferretdb/               # FerretDB StatefulSet (alternative, lightweight)
│   └── hyperdx/                # HyperDX deployment + init user job
├── nix/
│   ├── lib/                    # Shared utilities
│   │   ├── default.nix         # Library entry point
│   │   ├── shell.nix           # Shell script utilities
│   │   ├── containers.nix      # Container image factory
│   │   └── apps.nix            # Flake app helpers
│   ├── verify/                 # Pipeline verification (modular)
│   │   ├── default.nix         # Entry point
│   │   ├── positive.nix        # verify-* scripts
│   │   ├── init.nix            # init-clickhouse
│   │   ├── break-fix.nix       # break-*/fix-* pairs
│   │   ├── latency.nix         # measure-latency scripts
│   │   └── test-harness.nix    # test-verify-scripts
│   ├── microvm/                # MicroVM configurations
│   │   ├── default.nix         # Module entry point (variant selection)
│   │   ├── base.nix            # Shared NixOS config
│   │   ├── images.nix          # Container image loading
│   │   └── variants/
│   │       ├── docker.nix      # Docker Compose variant
│   │       ├── k3s.nix         # K3s variant (recommended)
│   │       └── minikube.nix    # Minikube variant
│   ├── go-app.nix              # Go application derivation
│   ├── fluentbit.nix           # FluentBit with custom config
│   ├── hyperdx.nix             # HyperDX built from source
│   ├── containers.nix          # OCI image definitions (uses lib/containers.nix)
│   ├── docker-compose.nix      # Docker Compose generator
│   ├── ports.nix               # Centralized port configuration
│   └── devshell.nix            # Development environment
├── flake.nix                   # Nix flake
├── DESIGN.md                   # Detailed design document
└── IMPLEMENTATION_LOG.md       # Implementation progress log
```

### Nix Architecture

The Nix codebase follows a modular architecture to reduce duplication and improve maintainability:

```
┌─────────────────────────────────────────────────────────────┐
│                        flake.nix                            │
│  (uses lib.genAttrs for DRY app definitions)                │
└─────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  containers.nix │  │  nix/verify/    │  │  nix/lib/       │
│  (OCI images)   │  │  (verification) │  │  (utilities)    │
└─────────────────┘  └─────────────────┘  └─────────────────┘
         │                    │                    │
         └────────────────────┼────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  nix/lib/       │
                    │  shell.nix      │  Shell script helpers
                    │  containers.nix │  Image factory (mkImage)
                    │  apps.nix       │  App helpers (mkApp)
                    └─────────────────┘
```

**Key patterns:**
- **`nix/lib/shell.nix`**: Common shell functions (colors, print helpers, pod utilities) and script factories (`mkVerifyScript`, `mkBreakScript`, `mkFixScript`)
- **`nix/lib/containers.nix`**: `mkImage` factory for building OCI images with standard defaults
- **`nix/lib/apps.nix`**: `mkApp` and `mkApps` helpers for flake app definitions
- **`nix/verify/break-fix.nix`**: Declarative break/fix pairs generating 14 scripts from config

## Kubernetes Deployment

### Deploy to Minikube

```bash
# Start minikube
minikube start

# Load images
minikube image load loggen:latest
minikube image load fluentbit:latest
minikube image load clickhouse:latest
minikube image load mongodb:latest
minikube image load hyperdx:latest

# Apply manifests
kubectl apply -k k8s/

# Wait for ClickHouse to be ready, then initialize schema
kubectl -n otel-demo wait --for=condition=ready pod -l app=clickhouse --timeout=120s
nix run .#init-clickhouse
```

### Verify Deployment

```bash
# Check pods
kubectl -n otel-demo get pods

# Verify pipeline is healthy
nix run .#verify-pipeline

# Check logs from loggen
kubectl -n otel-demo logs -l app=loggen

# Access HyperDX (via NodePort)
minikube service -n otel-demo hyperdx --url
```

Once HyperDX is accessible, login with the [demo credentials](#demo-credentials):
- **Email:** `demo@example.com`
- **Password:** `DemoPassword123!`

## MicroVM

The project includes MicroVM configurations for isolated testing with three variants optimized for different use cases.

### Variants

| Variant | RAM | vCPUs | Disk | Use Case |
|---------|-----|-------|------|----------|
| **k3s** (recommended) | 6 GB | 3 | 15 GB | Lightweight Kubernetes, fastest startup |
| **docker** | 4 GB | 2 | 15 GB | Direct Docker Compose, lowest resources |
| **minikube** | 8 GB | 4 | 20 GB | Full Minikube, most compatible |

### Quick Start

```bash
# Build and run the K3s variant (recommended)
nix build .#nixosConfigurations.microvm-k3s.config.microvm.declaredRunner
sudo ./result/bin/microvm-run

# Or run directly (builds if needed)
sudo nix run .#microvm-k3s
```

### Access Points

Once the VM is running:

| Service | URL/Command |
|---------|-------------|
| **SSH** | `ssh -p 22022 demo@localhost` (password: `demo`) |
| **HyperDX UI** | http://localhost:30808 |
| **HyperDX API** | http://localhost:30800 |
| **ClickHouse HTTP** | http://localhost:28123 |
| **ClickHouse Native** | localhost:29000 |

### Verify VM is Working

```bash
# SSH into the VM
ssh -p 22022 demo@localhost

# Check pod status (K3s variant)
sudo k3s kubectl -n otel-demo get pods

# Check logs are flowing
sudo k3s kubectl -n otel-demo exec clickhouse-0 -- \
  clickhouse-client --query 'SELECT count() FROM default.otel_logs'
```

### Variant Details

**K3s Variant** (`microvm-k3s`):
- Uses K3s lightweight Kubernetes
- Images loaded via `k3s ctr images import`
- Fastest boot time (~60s to fully operational)
- Recommended for most testing scenarios

**Docker Variant** (`microvm-docker`):
- Direct Docker Compose execution
- Lowest resource requirements
- Best for resource-constrained environments

**Minikube Variant** (`microvm-minikube`):
- Full Minikube with Docker driver
- Most compatible with standard Kubernetes tooling
- Highest resource requirements

### MicroVM Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Host System                              │
│  ┌─────────────────────────────────────────────────────┐    │
│  │                   MicroVM (QEMU)                     │    │
│  │  ┌─────────────────────────────────────────────┐    │    │
│  │  │     K3s / Minikube / Docker                  │    │    │
│  │  │  ┌─────────┐ ┌─────────┐ ┌─────────┐        │    │    │
│  │  │  │ loggen  │ │fluentbit│ │clickhouse│        │    │    │
│  │  │  └─────────┘ └─────────┘ └─────────┘        │    │    │
│  │  │  ┌─────────┐ ┌─────────┐                    │    │    │
│  │  │  │ mongodb │ │ hyperdx │                    │    │    │
│  │  │  └─────────┘ └─────────┘                    │    │    │
│  │  └─────────────────────────────────────────────┘    │    │
│  └─────────────────────────────────────────────────────┘    │
│         Port Forwards: 22022, 28123, 30800, 30808           │
└─────────────────────────────────────────────────────────────┘
```

## Development

```bash
# Enter development shell with all tools
nix develop

# Available tools:
# - go (1.26)
# - golangci-lint
# - kubectl, minikube, helm
# - docker, skopeo
# - clickhouse client
```

## Technical Notes

### HyperDX Build
HyperDX is built from source using:
- **yarn-berry** from nixpkgs for Yarn 4 support
- **fetchYarnBerryDeps** for reproducible offline builds
- Local fonts (Inter, IBM Plex Mono, Roboto, Roboto Mono) from nixpkgs to avoid Google Fonts CDN access during build
- **tsconfig-paths/register** at runtime to resolve TypeScript path aliases (`@/*` → `build/src/*`)

### FluentBit Configuration
FluentBit uses a Lua script (`nix/lua/transform.lua`) to transform JSON logs to OpenTelemetry format before sending to ClickHouse. Key features:
- Kubernetes filter for pod metadata enrichment (labels, node name)
- 2-second flush interval for batch efficiency
- Async inserts (`async_insert=1`) for better ClickHouse throughput
- Gzip compression for reduced network bandwidth
- Dynamic service name extraction from K8s labels (`app`, `app.kubernetes.io/name`, `k8s-app`)
- ObservedTimestamp tracking for pipeline latency measurement

### ClickHouse Schema
The `otel_logs` table is compatible with HyperDX's expected schema, including proper timestamp handling and JSON body storage. Key features:
- `ObservedTimestamp` column for pipeline latency measurement
- MATERIALIZED columns: `ContainerName`, `PodName`, `NamespaceName`, `NodeName` (auto-extracted from ResourceAttributes)
- Bloom filter indexes: `idx_trace_id`, `idx_container`, `idx_body`
- Set indexes: `idx_severity`, `idx_service`, `idx_namespace`, `idx_random_string`

### ClickHouse Size Optimization

A minimal ClickHouse build is available that disables unused features to reduce container size:

| Build | Binary | Container | Features Disabled |
|-------|--------|-----------|-------------------|
| **Full** | 748 MB | 355 MB | None (all features) |
| **Minimal** | 535 MB | 293 MB | Kafka, S3, MySQL, PostgreSQL, gRPC, Parquet, LLVM JIT, etc. |

The minimal build retains all features needed for the OTEL logging pipeline:
- MergeTree/SummingMergeTree engines
- JSONEachRow format (FluentBit integration)
- ZSTD/Delta compression
- Bloom filter indexes

**Usage:**
```bash
# Build minimal ClickHouse
nix build .#clickhouse-minimal

# Build minimal container image
nix build .#clickhouse-minimal-image
```

**Implementation:** [`nix/clickhouse-minimal.nix`](nix/clickhouse-minimal.nix)

**Detailed analysis:** [`docs/CLICKHOUSE_SIZE_OPTIMIZATION.md`](docs/CLICKHOUSE_SIZE_OPTIMIZATION.md)

## Pipeline Verification

The project includes comprehensive Nix-based verification scripts for testing each stage of the logging pipeline.

### Quick Verification

```bash
# Verify entire pipeline is healthy
nix run .#verify-pipeline

# Initialize ClickHouse schema (required after fresh deployment)
nix run .#init-clickhouse
```

### Individual Stage Verification

| Command | Description | Checks |
|---------|-------------|--------|
| `nix run .#verify-loggen` | Verify Go log generator | Pod running, health probes, JSON log format |
| `nix run .#verify-fluentbit` | Verify FluentBit collector | DaemonSet ready, pod health, no Lua errors |
| `nix run .#verify-fluentbit-output` | Verify FluentBit → ClickHouse | HTTP output success, no connection errors |
| `nix run .#verify-clickhouse` | Verify ClickHouse storage | Server responding, table exists, records present |
| `nix run .#verify-hyperdx` | Verify HyperDX UI | Pod ready, MongoDB connected, service endpoints |

### Sample Output

```
==============================================
Pipeline Verification Summary
==============================================

[PASS] loggen
[PASS] fluentbit
[PASS] fluentbit-output
[PASS] clickhouse
[PASS] hyperdx

==============================================
Passed: 5/5
Failed: 0/5
==============================================

ALL STAGES PASSED - Pipeline is healthy!
```

## Latency Measurement

Measure end-to-end pipeline latency from log emission to ClickHouse availability:

| Command | Description |
|---------|-------------|
| `nix run .#measure-latency` | Passive: analyze age of recent logs |
| `nix run .#measure-latency-active` | Active: wait for new logs and measure |

**Expected latency: 6-12 seconds** (FluentBit refresh: 5s, flush: 2s)

### Sample Output

```
==============================================
Latency Statistics
==============================================

  Samples analyzed:   10
  Window:             Last 60 seconds

  Minimum (freshest): 6.234 seconds
  Maximum (oldest):   11.456 seconds
  Average:            8.123 seconds

  P50 (median):       7.891 seconds
  P90:                10.234 seconds
  P99:                11.456 seconds
```

The latency includes:
1. Container runtime writing log to file
2. FluentBit tail refresh interval (configured: 5s)
3. FluentBit processing (Lua transformation)
4. FluentBit flush interval (configured: 2s)
5. Network transfer to ClickHouse
6. ClickHouse write and indexing

## Failure Injection Testing

The project includes failure injection scripts to verify that the verification scripts correctly detect failures.

### Break/Fix Commands

Each component has corresponding break and fix commands:

| Component | Break Command | Fix Command |
|-----------|---------------|-------------|
| **loggen** | `nix run .#break-loggen` | `nix run .#fix-loggen` |
| **fluentbit** | `nix run .#break-fluentbit` | `nix run .#fix-fluentbit` |
| **fluentbit-lua** | `nix run .#break-fluentbit-lua` | `nix run .#fix-fluentbit-lua` |
| **fluentbit-output** | `nix run .#break-fluentbit-output` | `nix run .#fix-fluentbit-output` |
| **clickhouse** | `nix run .#break-clickhouse` | `nix run .#fix-clickhouse` |
| **clickhouse-table** | `nix run .#break-clickhouse-table` | `nix run .#fix-clickhouse-table` |
| **hyperdx** | `nix run .#break-hyperdx` | `nix run .#fix-hyperdx` |

### Manual Failure Testing

```bash
# 1. Break a component
nix run .#break-loggen

# 2. Verify failure is detected
nix run .#verify-loggen  # Should fail with "Pod not running"

# 3. Restore the component
nix run .#fix-loggen

# 4. Verify recovery
nix run .#verify-loggen  # Should pass
```

### Automated Test Harness

Run all failure injection tests automatically:

```bash
nix run .#test-verify-scripts
```

This will:
1. Inject failure for each component
2. Verify the verification script detects the failure
3. Restore the component
4. Verify the verification script confirms recovery
5. Report summary of all tests

### Failure Injection Details

| Failure Type | What It Does | Expected Detection |
|--------------|--------------|-------------------|
| `break-loggen` | Scales deployment to 0 | "Pod not running" |
| `break-fluentbit` | Patches with invalid image | "DaemonSet not ready" |
| `break-fluentbit-lua` | Injects Lua syntax error | Lua errors in logs |
| `break-fluentbit-output` | Points to wrong ClickHouse host | Connection errors |
| `break-clickhouse` | Scales StatefulSet to 0 | "Pod not running" |
| `break-clickhouse-table` | Drops otel_logs table | "Table does not exist" |
| `break-hyperdx` | Scales deployment to 0 | "Pod not running" |

## Integration Testing

### Verified Components

The following components have been tested and verified working:

| Component | Test | Result |
|-----------|------|--------|
| **loggen** | Container produces JSON logs | ✅ Pass |
| **clickhouse** | HTTP API responds to queries | ✅ Pass |
| **mongodb** | Accepts connections on port 27017 | ✅ Pass |
| **hyperdx** | Next.js frontend starts | ✅ Pass |
| **hyperdx** | API loads with MongoDB | ✅ Pass |

### 1. Local Container Testing

```bash
# Load all images into Docker
nix run .#load-images

# Start ClickHouse
docker run -d --name clickhouse -p 8123:8123 -p 9000:9000 clickhouse:latest

# Verify ClickHouse is running
curl http://localhost:8123/ping

# Start loggen and capture output
docker run --rm loggen:latest
```

### 2. Minikube Deployment Testing

```bash
# Start minikube
minikube start --cpus=4 --memory=8g

# Load images into minikube
for img in loggen fluentbit clickhouse mongodb hyperdx; do
  docker save ${img}:latest | minikube image load -
done

# Deploy the stack
kubectl apply -k k8s/

# Wait for pods to be ready
kubectl -n otel-demo wait --for=condition=Ready pods --all --timeout=300s

# Verify all pods are running
kubectl -n otel-demo get pods
```

### 3. Pipeline Validation

| Test | Command | Expected Result |
|------|---------|-----------------|
| Loggen producing logs | `kubectl -n otel-demo logs -l app=loggen --tail=10` | JSON logs with random numbers and strings |
| FluentBit collecting | `kubectl -n otel-demo logs -l app=fluentbit --tail=10` | Log processing messages |
| ClickHouse receiving | `kubectl -n otel-demo exec -it sts/clickhouse -- clickhouse-client -q "SELECT count() FROM otel_logs"` | Row count > 0 |
| HyperDX accessible | `minikube service -n otel-demo hyperdx --url` | Web UI loads |

### 4. Query Validation

```bash
# Connect to ClickHouse and verify data
kubectl -n otel-demo exec -it sts/clickhouse -- clickhouse-client

# Run test queries:
SELECT count() FROM otel_logs;
SELECT * FROM otel_logs LIMIT 5;
SELECT Body FROM otel_logs WHERE Body LIKE '%number%' LIMIT 5;
```

### 5. HyperDX UI Validation

1. Access HyperDX via the NodePort URL
2. Login with [demo credentials](#demo-credentials) (`demo@example.com` / `DemoPassword123!`)
3. Verify connection to ClickHouse
4. Run a search query for logs containing a specific random word
5. Verify log aggregation by the random number field

### 6. MicroVM Testing

The project includes three MicroVM variants. The K3s variant is recommended for testing.

```bash
# Build and run the K3s MicroVM (recommended)
nix build .#nixosConfigurations.microvm-k3s.config.microvm.declaredRunner
sudo ./result/bin/microvm-run

# Or build and run other variants:
# sudo nix run .#microvm-docker    # Docker Compose (4GB RAM)
# sudo nix run .#microvm-minikube  # Minikube (8GB RAM)

# SSH into the VM (from another terminal)
ssh -p 22022 demo@localhost  # password: demo

# Inside the VM, verify services are running (K3s variant)
sudo systemctl status k3s load-images deploy-manifests
sudo k3s kubectl -n otel-demo get pods

# Verify logs are flowing to ClickHouse
sudo k3s kubectl -n otel-demo exec clickhouse-0 -- \
  clickhouse-client --query 'SELECT count() FROM default.otel_logs'

# Access HyperDX from host browser
# http://localhost:30808
```

**Expected startup sequence:**
1. VM boots (~10s)
2. K3s starts (~30s)
3. Images loaded into containerd (~30s)
4. Manifests deployed (~15s)
5. All pods running (~30s)

**Total time to operational:** ~2 minutes

### HyperDX Environment Variables

HyperDX requires MongoDB and additional configuration. Key environment variables:

| Variable | Required | Description |
|----------|----------|-------------|
| `MONGO_URI` | Yes | MongoDB connection string for session storage |
| `CLICKHOUSE_HOST` | Yes | ClickHouse server host |
| `CLICKHOUSE_PORT` | No | ClickHouse HTTP port (default: 8123) |
| `HYPERDX_API_PORT` | No | API server port (default: 8000) |
| `HYPERDX_APP_PORT` | No | Next.js app port (default: 8080) |

### Known Limitations

- MicroVM networking uses user-mode (SLIRP) which has performance limitations
- MicroVM requires `sudo` for disk image creation and KVM access
- First build of HyperDX takes significant time due to yarn dependency fetching
- MongoDB image is relatively large (~500MB) as it uses nixpkgs mongodb
- K3s variant is recommended over Minikube for lower resource usage

## License

MIT
