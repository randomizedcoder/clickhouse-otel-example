# ClickHouse OpenTelemetry Pipeline Demo

**Last Updated:** 2026-02-19

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

## What's Built

All components are built reproducibly with Nix - no Docker Hub pulls required.

| Component | Description | Image Size | Status |
|-----------|-------------|------------|--------|
| **loggen** | Go application generating random JSON logs | 3.3 MB | ✅ Working |
| **fluentbit** | Log collector with Lua OTel transformation | 75 MB | ✅ Working |
| **clickhouse** | Column-oriented database for log storage | 355 MB | ✅ Working |
| **hyperdx** | Observability UI (built from source) | 698 MB | ✅ Working |

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
- Lua script transforms JSON to OpenTelemetry format
- Outputs to ClickHouse HTTP interface

### ClickHouse
- HyperDX-compatible `otel_logs` table schema
- Materialized views for efficient querying
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
| HyperDX API | 8000 |
| HyperDX App | 8080 |

**Host Forwards (MicroVM → Host):**
| Service | Port |
|---------|------|
| SSH | 22022 |
| FluentBit Metrics | 22020 |
| ClickHouse HTTP | 28123 |
| ClickHouse Native | 29000 |
| HyperDX API | 28000 |
| HyperDX App | 28080 |

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
│   └── hyperdx/                # HyperDX deployment
├── nix/
│   ├── go-app.nix              # Go application derivation
│   ├── fluentbit.nix           # FluentBit with custom config
│   ├── hyperdx.nix             # HyperDX built from source
│   ├── containers.nix          # OCI image definitions
│   ├── microvm.nix             # MicroVM configuration
│   ├── ports.nix               # Centralized port configuration
│   └── devshell.nix            # Development environment
├── flake.nix                   # Nix flake
├── DESIGN.md                   # Detailed design document
└── IMPLEMENTATION_LOG.md       # Implementation progress log
```

## Kubernetes Deployment

### Deploy to Minikube

```bash
# Start minikube
minikube start

# Load images
minikube image load loggen:latest
minikube image load fluentbit:latest
minikube image load clickhouse:latest
minikube image load hyperdx:latest

# Apply manifests
kubectl apply -k k8s/
```

### Verify Deployment

```bash
# Check pods
kubectl -n otel-demo get pods

# Check logs from loggen
kubectl -n otel-demo logs -l app=loggen

# Access HyperDX (via NodePort)
minikube service -n otel-demo hyperdx --url
```

## MicroVM

The project includes a MicroVM configuration for isolated testing:

```bash
# Build and run the MicroVM
nix build .#nixosConfigurations.microvm.config.system.build.vm
./result/bin/run-otel-demo-vm
```

**MicroVM Specs:**
- 8 GB RAM
- 4 vCPUs
- QEMU hypervisor
- User-mode networking with port forwards

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

### FluentBit Configuration
FluentBit uses a Lua script (`nix/lua/transform.lua`) to transform JSON logs to OpenTelemetry format before sending to ClickHouse.

### ClickHouse Schema
The `otel_logs` table is compatible with HyperDX's expected schema, including proper timestamp handling and JSON body storage.

## Next Steps: Integration Testing

The following integration tests need to be performed to validate the complete pipeline:

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
for img in loggen fluentbit clickhouse hyperdx; do
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
2. Verify connection to ClickHouse
3. Run a search query for logs containing a specific random word
4. Verify log aggregation by the random number field

### 6. MicroVM Testing (Optional)

```bash
# Build the MicroVM
nix build .#nixosConfigurations.microvm.config.system.build.vm

# Run the VM
./result/bin/run-otel-demo-vm

# SSH into the VM (from another terminal)
ssh -p 22022 demo@localhost  # password: demo

# Inside the VM, verify minikube started
minikube status
kubectl get pods -A
```

### Known Limitations

- HyperDX requires MongoDB for session storage (not included in this demo)
- MicroVM networking uses user-mode (SLIRP) which has performance limitations
- First build of HyperDX takes significant time due to yarn dependency fetching

## License

MIT
