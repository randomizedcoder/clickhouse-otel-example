# MicroVM Variants Implementation Plan

## Overview

Refactor the monolithic `nix/microvm.nix` into a modular system supporting three container orchestration variants:

1. **microvm-docker** - Docker Compose, direct container execution
2. **microvm-minikube** - Minikube with Docker driver, full Kubernetes
3. **microvm-k3s** - K3s lightweight Kubernetes

Each variant runs the same workloads (loggen, fluentbit, clickhouse, mongodb, hyperdx) using the same Nix-built container images.

---

## Nix Store Caching Strategy

### Goal: Maximize `/nix/store` Sharing Between Variants

Building one variant should accelerate building others by sharing common derivations.

### Caching Layers

```
┌─────────────────────────────────────────────────────────────────┐
│ Layer 4: Variant-Specific (NOT shared)                          │
│ - erofs store image (different closure per variant)             │
│ - Variant systemd units                                         │
├─────────────────────────────────────────────────────────────────┤
│ Layer 3: Container Images (SHARED across all variants)          │
│ - loggen-image, fluentbit-image, clickhouse-image               │
│ - mongodb-image, hyperdx-image                                  │
│ - Same derivation paths, built once                             │
├─────────────────────────────────────────────────────────────────┤
│ Layer 2: K8s Manifests (SHARED for k3s/minikube)                │
│ - k8sManifests derivation (kustomize output)                    │
│ - Docker variant uses generated compose file instead            │
├─────────────────────────────────────────────────────────────────┤
│ Layer 1: Base NixOS System (SHARED across all variants)         │
│ - Common packages (vim, curl, jq, htop, tmux, clickhouse)       │
│ - SSH config, user accounts, firewall rules                     │
│ - Nix settings, journald config                                 │
├─────────────────────────────────────────────────────────────────┤
│ Layer 0: Nixpkgs (SHARED - single input)                        │
│ - All packages from same nixpkgs revision                       │
│ - Compiler toolchains, libraries                                │
└─────────────────────────────────────────────────────────────────┘
```

### Implementation Techniques

#### 1. Single Nixpkgs Input
```nix
# flake.nix - all variants use same nixpkgs
inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

# All nixosConfigurations use same nixpkgs
nixosConfigurations.microvm-docker = nixpkgs.lib.nixosSystem { ... };
nixosConfigurations.microvm-k3s = nixpkgs.lib.nixosSystem { ... };
```

#### 2. Shared Base Package Set
```nix
# nix/microvm/base.nix
{ pkgs, ... }:
{
  # These packages are identical derivations across all variants
  environment.systemPackages = with pkgs; [
    vim curl jq htop tmux
    clickhouse  # client for debugging
  ];

  # Variant-specific packages added via mkAfter
}
```

#### 3. Container Images as Flake Packages
```nix
# flake.nix - images built once, referenced by all variants
packages.x86_64-linux = {
  loggen-image = containers.loggenImage;      # /nix/store/abc...-docker-image-loggen.tar.gz
  fluentbit-image = containers.fluentbitImage; # /nix/store/def...-docker-image-fluentbit.tar.gz
  # ... same store paths used by all variants
};
```

#### 4. Shared K8s Manifests Derivation
```nix
# nix/microvm/manifests.nix
{ pkgs, k8sManifestsPath, ... }:
let
  # Single derivation, same path for k3s and minikube
  k8sManifests = pkgs.runCommand "k8s-manifests" {} ''
    mkdir -p $out
    cp -r ${k8sManifestsPath}/* $out/
  '';
in {
  _module.args.k8sManifests = k8sManifests;
}
```

#### 5. Lazy Variant-Specific Additions
```nix
# nix/microvm/variants/docker.nix
{ pkgs, lib, ... }:
{
  # Only adds docker-specific packages
  environment.systemPackages = lib.mkAfter (with pkgs; [
    docker
    docker-compose
  ]);
}

# nix/microvm/variants/k3s.nix
{ pkgs, lib, ... }:
{
  environment.systemPackages = lib.mkAfter (with pkgs; [
    k3s
    # kubectl comes with k3s
  ]);
}
```

### Cache Effectiveness Analysis

| Component | Size | Shared? | Build Time |
|-----------|------|---------|------------|
| nixpkgs base | ~500MB | Yes (all) | 0 (cached) |
| Common packages | ~200MB | Yes (all) | 0 (cached) |
| Container images | ~2GB | Yes (all) | ~5min (once) |
| K8s manifests | ~50KB | Yes (k3s/minikube) | ~1s (once) |
| Docker daemon | ~100MB | Yes (docker/minikube) | 0 (cached) |
| K3s binary | ~60MB | Yes (k3s only) | 0 (cached) |
| Minikube | ~80MB | Yes (minikube only) | 0 (cached) |
| erofs image | ~2-3GB | No (per variant) | ~8min each |

**First variant build:** ~15-20 minutes (container images + erofs)
**Subsequent variants:** ~8-10 minutes (only erofs rebuild)
**Rebuild same variant:** ~1-2 minutes (if no changes)

### Binary Cache Integration

```nix
# flake.nix - configure substituters for CI caching
nixConfig = {
  extra-substituters = [
    "https://cache.nixos.org"
    "https://nix-community.cachix.org"  # Optional: community cache
    # "https://your-org.cachix.org"     # Optional: private cache
  ];
  extra-trusted-public-keys = [
    "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
    "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
  ];
};
```

### CI Caching Workflow

```yaml
# .github/workflows/ci.yml
jobs:
  build:
    steps:
      - uses: cachix/install-nix-action@v22
      - uses: cachix/cachix-action@v12
        with:
          name: your-cache
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'

      # Build in order to maximize cache hits
      - run: nix build .#packages.x86_64-linux.all-images  # Container images first
      - run: nix build .#nixosConfigurations.microvm-docker.config.system.build.toplevel
      - run: nix build .#nixosConfigurations.microvm-k3s.config.system.build.toplevel
      - run: nix build .#nixosConfigurations.microvm-minikube.config.system.build.toplevel
```

---

## Automated Validation

### Validation Pipeline

```
┌─────────────────────────────────────────────────────────────────┐
│                      nix flake check                            │
│  (Runs automatically, fails fast on any error)                  │
└─────────────────────────────────────────────────────────────────┘
                              │
          ┌───────────────────┼───────────────────┐
          ▼                   ▼                   ▼
   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
   │ Eval Tests  │     │ Build Tests │     │  VM Tests   │
   │   (~10s)    │     │   (~3min)   │     │  (~10min)   │
   └─────────────┘     └─────────────┘     └─────────────┘
          │                   │                   │
          ▼                   ▼                   ▼
   ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
   │ Config      │     │ Derivations │     │ Services    │
   │ evaluates   │     │ build       │     │ start       │
   │ without     │     │ without     │     │ containers  │
   │ errors      │     │ errors      │     │ run         │
   └─────────────┘     └─────────────┘     └─────────────┘
```

### Flake Checks Structure

```nix
# flake.nix
{
  checks.x86_64-linux = let
    inherit (nixpkgs) lib;
    pkgs = nixpkgs.legacyPackages.x86_64-linux;

    # Import test definitions
    vmTests = import ./nix/microvm/tests {
      inherit pkgs self;
    };
  in {
    # ═══════════════════════════════════════════════════════════
    # Level 0: Evaluation Tests (instant feedback)
    # ═══════════════════════════════════════════════════════════

    eval-microvm-docker = pkgs.runCommand "eval-microvm-docker" {} ''
      # Verify configuration evaluates without infinite recursion or errors
      echo "Evaluating microvm-docker configuration..."
      touch $out
    '';

    eval-microvm-k3s = pkgs.runCommand "eval-microvm-k3s" {} ''
      echo "Evaluating microvm-k3s configuration..."
      touch $out
    '';

    eval-microvm-minikube = pkgs.runCommand "eval-microvm-minikube" {} ''
      echo "Evaluating microvm-minikube configuration..."
      touch $out
    '';

    # ═══════════════════════════════════════════════════════════
    # Level 1: Build Tests (derivation builds successfully)
    # ═══════════════════════════════════════════════════════════

    # These are implicit - if the derivation is referenced, it must build
    build-microvm-docker =
      self.nixosConfigurations.microvm-docker.config.system.build.toplevel;

    build-microvm-k3s =
      self.nixosConfigurations.microvm-k3s.config.system.build.toplevel;

    build-microvm-minikube =
      self.nixosConfigurations.microvm-minikube.config.system.build.toplevel;

    # ═══════════════════════════════════════════════════════════
    # Level 2: VM Smoke Tests (services start correctly)
    # ═══════════════════════════════════════════════════════════

    vm-smoke-docker = vmTests.docker-smoke;
    vm-smoke-k3s = vmTests.k3s-smoke;
    # vm-smoke-minikube = vmTests.minikube-smoke;  # Optional: resource-heavy

    # ═══════════════════════════════════════════════════════════
    # Level 3: Integration Tests (full pipeline verification)
    # ═══════════════════════════════════════════════════════════

    vm-integration = vmTests.pipeline-integration;
  };
}
```

### NixOS Test Framework Details

```nix
# nix/microvm/tests/default.nix
{ pkgs, self }:

let
  # NixOS test infrastructure
  nixosTest = test: pkgs.nixosTest test;

  # Shared test utilities
  testLib = import ./lib.nix { inherit pkgs; };

in {
  # ─────────────────────────────────────────────────────────────
  # Docker Variant Smoke Test
  # ─────────────────────────────────────────────────────────────
  docker-smoke = nixosTest {
    name = "microvm-docker-smoke";

    nodes.machine = { config, pkgs, ... }: {
      imports = [
        self.nixosModules.microvm-docker
      ];

      # Test VM resources (not the actual microvm resources)
      virtualisation = {
        memorySize = 4096;
        cores = 2;
        diskSize = 16384;
      };
    };

    testScript = ''
      # ── Phase 1: Boot and basic services ──
      machine.start()
      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("docker.service")

      # ── Phase 2: Image loading ──
      machine.wait_for_unit("load-images.service", timeout=300)

      # Verify images loaded
      machine.succeed("docker images | grep loggen")
      machine.succeed("docker images | grep fluentbit")
      machine.succeed("docker images | grep clickhouse")
      machine.succeed("docker images | grep hyperdx")

      # ── Phase 3: Container startup ──
      machine.wait_for_unit("otel-demo.service", timeout=120)

      # Verify containers running
      machine.succeed("docker ps | grep loggen")
      machine.succeed("docker ps | grep fluentbit")
      machine.succeed("docker ps | grep clickhouse")
      machine.succeed("docker ps | grep hyperdx")

      # ── Phase 4: Health checks ──
      machine.wait_until_succeeds(
        "curl -sf http://localhost:8123/ping",
        timeout=60
      )
      machine.wait_until_succeeds(
        "curl -sf http://localhost:8080/",
        timeout=60
      )

      # ── Phase 5: Basic functionality ──
      # Verify ClickHouse accepts queries
      machine.succeed(
        "docker exec clickhouse clickhouse-client --query 'SELECT 1'"
      )
    '';
  };

  # ─────────────────────────────────────────────────────────────
  # K3s Variant Smoke Test
  # ─────────────────────────────────────────────────────────────
  k3s-smoke = nixosTest {
    name = "microvm-k3s-smoke";

    nodes.machine = { config, pkgs, ... }: {
      imports = [
        self.nixosModules.microvm-k3s
      ];

      virtualisation = {
        memorySize = 6144;
        cores = 3;
        diskSize = 16384;
      };
    };

    testScript = ''
      # ── Phase 1: Boot and K3s startup ──
      machine.start()
      machine.wait_for_unit("k3s.service", timeout=120)

      # Wait for K3s to be ready
      machine.wait_until_succeeds(
        "k3s kubectl get nodes | grep -w Ready",
        timeout=120
      )

      # ── Phase 2: Image loading ──
      machine.wait_for_unit("load-images.service", timeout=300)

      # Verify images in containerd
      machine.succeed("k3s ctr images ls | grep loggen")
      machine.succeed("k3s ctr images ls | grep clickhouse")

      # ── Phase 3: Manifest deployment ──
      machine.wait_for_unit("deploy-manifests.service", timeout=120)

      # ── Phase 4: Wait for pods ──
      machine.wait_until_succeeds(
        "k3s kubectl -n otel-demo get pods | grep loggen | grep Running",
        timeout=300
      )
      machine.wait_until_succeeds(
        "k3s kubectl -n otel-demo get pods | grep clickhouse | grep Running",
        timeout=300
      )
      machine.wait_until_succeeds(
        "k3s kubectl -n otel-demo get pods | grep hyperdx | grep Running",
        timeout=300
      )

      # ── Phase 5: Service health ──
      machine.wait_until_succeeds(
        "curl -sf http://localhost:30808/",  # HyperDX NodePort
        timeout=60
      )
    '';
  };

  # ─────────────────────────────────────────────────────────────
  # Full Pipeline Integration Test
  # ─────────────────────────────────────────────────────────────
  pipeline-integration = nixosTest {
    name = "otel-pipeline-integration";

    nodes.machine = { config, pkgs, ... }: {
      imports = [
        self.nixosModules.microvm-k3s  # K3s for faster startup
      ];

      virtualisation = {
        memorySize = 6144;
        cores = 3;
        diskSize = 16384;
      };
    };

    testScript = ''
      import json
      import time

      machine.start()

      # ── Phase 1: Infrastructure ready ──
      machine.wait_for_unit("k3s.service", timeout=120)
      machine.wait_for_unit("deploy-manifests.service", timeout=300)

      # Wait for all pods
      machine.wait_until_succeeds(
        "k3s kubectl -n otel-demo wait --for=condition=Ready pods --all --timeout=300s"
      )

      # ── Phase 2: Log Generation ──
      # Verify loggen is producing logs
      machine.wait_until_succeeds(
        "k3s kubectl -n otel-demo logs deploy/loggen 2>&1 | head -5 | grep -q .",
        timeout=60
      )
      print("✓ Loggen producing logs")

      # ── Phase 3: FluentBit Processing ──
      # Check FluentBit metrics endpoint
      machine.wait_until_succeeds(
        "curl -sf http://localhost:2020/api/v1/metrics | grep -q fluentbit",
        timeout=60
      )
      print("✓ FluentBit processing")

      # ── Phase 4: ClickHouse Storage ──
      # Wait for data to appear in ClickHouse
      machine.wait_until_succeeds(
        """k3s kubectl -n otel-demo exec deploy/clickhouse -- \
           clickhouse-client --query 'SELECT count() FROM otel.logs' | \
           grep -v '^0$'""",
        timeout=180
      )

      # Get actual count
      count = machine.succeed(
        """k3s kubectl -n otel-demo exec deploy/clickhouse -- \
           clickhouse-client --query 'SELECT count() FROM otel.logs'"""
      ).strip()
      print(f"✓ ClickHouse has {count} log entries")

      # ── Phase 5: HyperDX Query ──
      # Verify HyperDX API is responding
      machine.wait_until_succeeds(
        "curl -sf http://localhost:30800/health",
        timeout=60
      )
      print("✓ HyperDX API healthy")

      # ── Phase 6: End-to-End Latency ──
      # Measure pipeline latency (time from log generation to query)
      start_time = time.time()

      # Generate a unique marker log
      marker = f"INTEGRATION_TEST_{int(time.time())}"
      machine.succeed(
        f"""k3s kubectl -n otel-demo exec deploy/loggen -- \
            /bin/sh -c 'echo "{marker}" >> /dev/stdout'"""
      )

      # Wait for it to appear in ClickHouse
      machine.wait_until_succeeds(
        f"""k3s kubectl -n otel-demo exec deploy/clickhouse -- \
            clickhouse-client --query "SELECT count() FROM otel.logs WHERE message LIKE '%{marker}%'" | \
            grep -v '^0$'""",
        timeout=120
      )

      latency = time.time() - start_time
      print(f"✓ Pipeline latency: {latency:.1f}s")

      # Assert reasonable latency (< 60s for demo)
      assert latency < 60, f"Pipeline latency too high: {latency}s"

      print("═══════════════════════════════════════")
      print("  All integration tests passed!")
      print("═══════════════════════════════════════")
    '';
  };
}
```

### Running Validation

```bash
# ═══════════════════════════════════════════════════════════════
# Full validation suite (CI default)
# ═══════════════════════════════════════════════════════════════
nix flake check

# ═══════════════════════════════════════════════════════════════
# Individual test levels
# ═══════════════════════════════════════════════════════════════

# Level 0: Quick eval check (~10s)
nix eval .#nixosConfigurations.microvm-docker.config.system.build.toplevel

# Level 1: Build test (~3min)
nix build .#checks.x86_64-linux.build-microvm-docker

# Level 2: Smoke test (~5min)
nix build .#checks.x86_64-linux.vm-smoke-docker
# View test output:
cat result/log

# Level 3: Integration test (~10min)
nix build .#checks.x86_64-linux.vm-integration

# ═══════════════════════════════════════════════════════════════
# Interactive debugging
# ═══════════════════════════════════════════════════════════════

# Run test interactively (drops to Python shell on failure)
nix build .#checks.x86_64-linux.vm-smoke-docker.driverInteractive
./result/bin/nixos-test-driver

# Inside the test driver:
>>> machine.start()
>>> machine.shell_interact()  # Opens shell in VM
```

### CI Integration (GitHub Actions)

```yaml
# .github/workflows/test.yml
name: Test MicroVM Variants

on:
  push:
    branches: [main]
  pull_request:

jobs:
  eval:
    name: Evaluate Configs
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v24
      - run: |
          nix eval .#nixosConfigurations.microvm-docker.config.system.build.toplevel
          nix eval .#nixosConfigurations.microvm-k3s.config.system.build.toplevel
          nix eval .#nixosConfigurations.microvm-minikube.config.system.build.toplevel

  build:
    name: Build Variants
    needs: eval
    runs-on: ubuntu-latest
    strategy:
      matrix:
        variant: [docker, k3s, minikube]
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v24
      - uses: cachix/cachix-action@v12
        with:
          name: otel-demo
          authToken: '${{ secrets.CACHIX_AUTH_TOKEN }}'
      - run: nix build .#nixosConfigurations.microvm-${{ matrix.variant }}.config.system.build.toplevel

  smoke-test:
    name: Smoke Tests
    needs: build
    runs-on: ubuntu-latest
    strategy:
      matrix:
        variant: [docker, k3s]  # Skip minikube (too resource-heavy)
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v24
        with:
          extra_nix_config: |
            system-features = kvm
      - uses: cachix/cachix-action@v12
        with:
          name: otel-demo
      - run: nix build .#checks.x86_64-linux.vm-smoke-${{ matrix.variant }}

  integration:
    name: Integration Test
    needs: smoke-test
    if: github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: cachix/install-nix-action@v24
        with:
          extra_nix_config: |
            system-features = kvm
      - uses: cachix/cachix-action@v12
        with:
          name: otel-demo
      - run: nix build .#checks.x86_64-linux.vm-integration
```

---

## Additional Nix Refactors (DRY & Idiomatic)

### Current State Analysis

**Good patterns already in use:**
- `nix/lib/containers.nix` - Container factory with `mkImage`
- `nix/verify/break-fix.nix` - Declarative break/fix pairs with `lib.mapAttrs'`
- `nix/lib/shell.nix` - Shared shell utilities
- `lib.genAttrs` for app generation

**Opportunities for improvement:**

### 1. Flake-Parts for Modular Flake Structure

**Problem:** `flake.nix` is monolithic with repeated patterns per-system.

**Solution:** Use [flake-parts](https://flake.parts) for modular composition.

```nix
# flake.nix (before - 207 lines)
{
  outputs = { self, nixpkgs, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        # ... repeated setup per system
      in { ... }
    );
}

# flake.nix (after - ~50 lines)
{
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];

      imports = [
        ./nix/flake-modules/packages.nix
        ./nix/flake-modules/containers.nix
        ./nix/flake-modules/devshell.nix
        ./nix/flake-modules/checks.nix
        ./nix/flake-modules/microvms.nix
      ];
    };
}
```

**Benefits:**
- Each module is self-contained
- Better caching (modules only rebuild when their inputs change)
- Cleaner separation of concerns
- Easier testing of individual modules

### 2. Unified Service Definition (Single Source of Truth)

**Problem:** Service configuration scattered across:
- `nix/ports.nix` - Port numbers
- `nix/containers.nix` - Image configs
- `k8s/*.yaml` - Kubernetes manifests
- Future: `docker-compose.yaml`

**Solution:** Single service definition that generates all artifacts.

```nix
# nix/services/default.nix
{ lib, pkgs }:
let
  # Single source of truth for all services
  services = {
    loggen = {
      description = "Log generator for OTel pipeline";
      package = pkgs.callPackage ../go-app.nix {};

      ports = {
        health = { container = 8081; nodePort = 30081; };
      };

      container = {
        entrypoint = [ "/bin/loggen" ];
        env = {
          LOGGEN_MAX_NUMBER = "100";
          LOGGEN_SLEEP_DURATION = "5s";
        };
      };

      kubernetes = {
        kind = "Deployment";
        replicas = 1;
        resources = {
          requests = { memory = "64Mi"; cpu = "100m"; };
          limits = { memory = "128Mi"; cpu = "200m"; };
        };
      };
    };

    clickhouse = {
      description = "ClickHouse OLAP database";
      package = pkgs.clickhouse;

      ports = {
        http = { container = 8123; nodePort = 30123; hostForward = 28123; };
        native = { container = 9000; nodePort = 30900; hostForward = 29000; };
      };

      container = { /* ... */ };

      kubernetes = {
        kind = "StatefulSet";
        replicas = 1;
        volumeClaims = [{ name = "data"; size = "10Gi"; }];
      };
    };

    # ... other services
  };

  # Generators
  generators = import ./generators.nix { inherit lib pkgs services; };

in {
  inherit services;

  # Generated artifacts
  ports = generators.mkPorts services;
  containers = generators.mkContainers services;
  k8sManifests = generators.mkK8sManifests services;
  dockerCompose = generators.mkDockerCompose services;
}
```

```nix
# nix/services/generators.nix
{ lib, pkgs, services }:
{
  # Generate ports.nix equivalent
  mkPorts = services: {
    services = lib.mapAttrs (_: svc:
      lib.mapAttrs (_: port: port.container) svc.ports
    ) services;

    nodePorts = lib.mapAttrs (_: svc:
      lib.filterAttrs (_: port: port ? nodePort)
        (lib.mapAttrs (_: port: port.nodePort) svc.ports)
    ) services;

    hostForwards = lib.mapAttrs (_: svc:
      lib.filterAttrs (_: port: port ? hostForward)
        (lib.mapAttrs (_: port: port.hostForward) svc.ports)
    ) services;
  };

  # Generate K8s manifests
  mkK8sManifests = services:
    pkgs.runCommand "k8s-manifests" {
      nativeBuildInputs = [ pkgs.yq-go ];
    } ''
      mkdir -p $out
      ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: svc: ''
        cat > $out/${name}.yaml << 'EOF'
        ${generators.serviceToYaml name svc}
        EOF
      '') services)}

      # Generate kustomization.yaml
      cat > $out/kustomization.yaml << 'EOF'
      apiVersion: kustomize.config.k8s.io/v1beta1
      kind: Kustomization
      resources:
      ${lib.concatMapStrings (name: "  - ${name}.yaml\n") (lib.attrNames services)}
      EOF
    '';

  # Generate docker-compose.yaml
  mkDockerCompose = services:
    pkgs.writeText "docker-compose.yaml" (lib.generators.toYAML {} {
      version = "3.8";
      services = lib.mapAttrs (name: svc: {
        image = "${name}:latest";
        ports = lib.mapAttrsToList (_: port:
          "${toString port.hostForward or port.container}:${toString port.container}"
        ) svc.ports;
        environment = svc.container.env or {};
      }) services;
    });
}
```

### 3. Overlay-Based Package Organization

**Problem:** Packages defined inline in flake, harder to override.

**Solution:** Use overlays for all custom packages.

```nix
# nix/overlays/default.nix
{ inputs }:
{
  # Main overlay with all custom packages
  default = final: prev: {
    otel-demo = {
      loggen = final.callPackage ../packages/loggen.nix {};
      fluentbit = final.callPackage ../packages/fluentbit.nix {};
      hyperdx = final.callPackage ../packages/hyperdx.nix {};

      # Container images
      images = final.callPackage ../containers {};

      # Verification scripts
      verify = final.callPackage ../verify {};
    };
  };

  # Development tools overlay
  dev = final: prev: {
    otel-demo-dev = {
      # Dev-only packages
    };
  };
}

# flake.nix
{
  overlays.default = import ./nix/overlays { inherit inputs; };

  # Apply overlay once, use everywhere
  legacyPackages.x86_64-linux = import nixpkgs {
    system = "x86_64-linux";
    overlays = [ self.overlays.default ];
  };
}
```

**Benefits:**
- Packages can be overridden by downstream users
- Single place to apply nixpkgs config
- Better `nix repl` experience

### 4. NixOS Module Options for Configuration

**Problem:** Configuration hardcoded in modules.

**Solution:** Proper NixOS options with types and defaults.

```nix
# nix/modules/otel-demo.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.services.otel-demo;
in {
  options.services.otel-demo = {
    enable = lib.mkEnableOption "OTel demo pipeline";

    variant = lib.mkOption {
      type = lib.types.enum [ "docker" "k3s" "minikube" ];
      default = "k3s";
      description = "Container orchestration variant";
    };

    services = {
      loggen = {
        enable = lib.mkEnableOption "log generator" // { default = true; };
        replicas = lib.mkOption {
          type = lib.types.int;
          default = 1;
        };
        sleepDuration = lib.mkOption {
          type = lib.types.str;
          default = "5s";
        };
      };

      clickhouse = {
        enable = lib.mkEnableOption "ClickHouse" // { default = true; };
        dataDir = lib.mkOption {
          type = lib.types.path;
          default = "/var/lib/clickhouse";
        };
      };

      # ... other services
    };

    ports = lib.mkOption {
      type = lib.types.attrsOf lib.types.port;
      default = import ../ports.nix;
      description = "Port configuration";
    };
  };

  config = lib.mkIf cfg.enable {
    # Generated configuration based on options
    virtualisation.oci-containers.containers = lib.mkIf (cfg.variant == "docker") {
      # ...
    };

    services.k3s = lib.mkIf (cfg.variant == "k3s") {
      # ...
    };
  };
}
```

### 5. Derivation Helpers for Cache Optimization

**Problem:** Large derivations rebuild unnecessarily.

**Solution:** Helper functions that split derivations for better caching.

```nix
# nix/lib/cache.nix
{ lib, pkgs }:
{
  # Split a large derivation into cacheable layers
  mkLayeredDerivation = { name, layers, final }:
    let
      builtLayers = lib.imap0 (i: layer:
        pkgs.runCommand "${name}-layer-${toString i}" {} layer
      ) layers;
    in
    pkgs.runCommand name {
      inherit builtLayers;
    } final;

  # Create a derivation that depends on file hash, not content
  mkContentAddressed = { name, src, builder }:
    let
      srcHash = builtins.hashFile "sha256" src;
    in
    pkgs.runCommand "${name}-${builtins.substring 0 8 srcHash}" {
      inherit src;
    } builder;

  # Wrapper for expensive builds with explicit cache key
  mkCached = { name, cacheKey, builder }:
    pkgs.runCommand "${name}-${builtins.hashString "sha256" cacheKey}" {} builder;
}
```

### 6. Generated K8s Manifests (Kubenix Pattern)

**Problem:** K8s YAML maintained separately, can drift from Nix definitions.

**Solution:** Generate K8s manifests from Nix.

```nix
# nix/k8s/default.nix
{ lib, pkgs, services }:
let
  mkDeployment = name: svc: {
    apiVersion = "apps/v1";
    kind = "Deployment";
    metadata = {
      inherit name;
      namespace = "otel-demo";
      labels.app = name;
    };
    spec = {
      replicas = svc.kubernetes.replicas or 1;
      selector.matchLabels.app = name;
      template = {
        metadata.labels.app = name;
        spec.containers = [{
          inherit name;
          image = "${name}:latest";
          imagePullPolicy = "Never";  # Use preloaded images
          ports = lib.mapAttrsToList (portName: port: {
            containerPort = port.container;
            name = portName;
          }) svc.ports;
          env = lib.mapAttrsToList (k: v: {
            name = k;
            value = toString v;
          }) (svc.container.env or {});
          resources = svc.kubernetes.resources or {};
        }];
      };
    };
  };

  mkService = name: svc: {
    apiVersion = "v1";
    kind = "Service";
    metadata = {
      inherit name;
      namespace = "otel-demo";
    };
    spec = {
      selector.app = name;
      type = if (lib.any (p: p ? nodePort) (lib.attrValues svc.ports))
             then "NodePort" else "ClusterIP";
      ports = lib.mapAttrsToList (portName: port: {
        name = portName;
        port = port.container;
        targetPort = port.container;
      } // lib.optionalAttrs (port ? nodePort) {
        nodePort = port.nodePort;
      }) svc.ports;
    };
  };

  allManifests = lib.flatten (lib.mapAttrsToList (name: svc: [
    (mkDeployment name svc)
    (mkService name svc)
  ]) services);

in pkgs.writeText "manifests.yaml" (
  lib.concatMapStringsSep "\n---\n"
    (m: builtins.toJSON m)  # Or use lib.generators.toYAML
    allManifests
)
```

### 7. Test Infrastructure Module

**Problem:** Test setup duplicated across test files.

**Solution:** Shared test infrastructure module.

```nix
# nix/testing/default.nix
{ lib, pkgs, self }:
let
  # Common test node configuration
  baseTestNode = { variant }: {
    imports = [ self.nixosModules."microvm-${variant}" ];

    # Override for test environment
    virtualisation = {
      memorySize = {
        docker = 4096;
        k3s = 6144;
        minikube = 8192;
      }.${variant};
      cores = { docker = 2; k3s = 3; minikube = 4; }.${variant};
    };
  };

  # Common test assertions
  assertions = {
    serviceRunning = service: ''
      machine.wait_for_unit("${service}.service")
    '';

    containerRunning = { variant, name }: {
      docker = ''machine.succeed("docker ps | grep ${name}")'';
      k3s = ''machine.succeed("k3s kubectl -n otel-demo get pods | grep ${name} | grep Running")'';
      minikube = ''machine.succeed("kubectl -n otel-demo get pods | grep ${name} | grep Running")'';
    }.${variant};

    httpHealthy = { url, timeout ? 60 }: ''
      machine.wait_until_succeeds(
        "curl -sf ${url}",
        timeout=${toString timeout}
      )
    '';

    pipelineFlowing = ''
      # Verify logs flow from loggen -> fluentbit -> clickhouse
      machine.wait_until_succeeds(
        "clickhouse-client --query 'SELECT count() FROM otel.logs' | grep -v '^0$'",
        timeout=180
      )
    '';
  };

  # Test builder
  mkTest = { name, variant, testScript, extraConfig ? {} }:
    pkgs.nixosTest {
      inherit name;
      nodes.machine = lib.recursiveUpdate (baseTestNode { inherit variant; }) extraConfig;
      testScript = ''
        ${assertions.serviceRunning "multi-user.target"}
        ${testScript}
      '';
    };

in {
  inherit baseTestNode assertions mkTest;

  # Pre-built test suites
  smokeTests = lib.genAttrs [ "docker" "k3s" "minikube" ] (variant:
    mkTest {
      name = "smoke-${variant}";
      inherit variant;
      testScript = ''
        ${assertions.containerRunning { inherit variant; name = "loggen"; }}
        ${assertions.containerRunning { inherit variant; name = "clickhouse"; }}
        ${assertions.httpHealthy { url = "http://localhost:8123/ping"; }}
      '';
    }
  );
}
```

### 8. Directory Structure After Refactoring

```
nix/
├── flake-modules/           # Flake-parts modules
│   ├── packages.nix
│   ├── containers.nix
│   ├── devshell.nix
│   ├── checks.nix
│   └── microvms.nix
│
├── overlays/                # Package overlays
│   └── default.nix
│
├── packages/                # Individual packages
│   ├── loggen.nix
│   ├── fluentbit.nix
│   └── hyperdx.nix
│
├── services/                # Unified service definitions
│   ├── default.nix          # Service declarations
│   ├── generators.nix       # Artifact generators
│   └── services/
│       ├── loggen.nix
│       ├── clickhouse.nix
│       └── ...
│
├── containers/              # Container image builders
│   ├── default.nix
│   └── lib.nix
│
├── k8s/                     # Generated K8s manifests
│   └── default.nix
│
├── microvm/                 # MicroVM variants
│   ├── default.nix
│   ├── base.nix
│   └── variants/
│
├── modules/                 # NixOS modules
│   └── otel-demo.nix
│
├── testing/                 # Test infrastructure
│   ├── default.nix
│   ├── assertions.nix
│   └── fixtures.nix
│
└── lib/                     # Shared utilities
    ├── default.nix
    ├── containers.nix
    ├── shell.nix
    └── cache.nix
```

### 9. Implementation Priority

| Refactor | Impact | Effort | Priority |
|----------|--------|--------|----------|
| Unified Service Definition | High (DRY) | Medium | 1 |
| Flake-Parts | High (maintainability) | Medium | 2 |
| Test Infrastructure Module | Medium (DRY) | Low | 3 |
| NixOS Module Options | Medium (flexibility) | Medium | 4 |
| Overlay Organization | Low (cleanliness) | Low | 5 |
| Generated K8s Manifests | Medium (consistency) | High | 6 |
| Cache Helpers | Low (performance) | Low | 7 |

### 10. Migration Strategy

**Phase 1: Foundation**
- Create `nix/services/` with unified service definitions
- Generate ports.nix from services (backwards compatible)

**Phase 2: Containers**
- Migrate container definitions to use service definitions
- Verify all images build identically

**Phase 3: Flake-Parts**
- Split flake.nix into modules
- Verify `nix flake check` passes

**Phase 4: K8s Generation**
- Generate K8s manifests from service definitions
- Keep k8s/ directory as generated output (for visibility)

**Phase 5: Testing**
- Create shared test infrastructure
- Migrate existing tests to use new patterns

---

## Architecture

### Directory Structure

```
nix/
├── microvm/
│   ├── default.nix          # Module entry point, exports all variants
│   ├── base.nix              # Shared NixOS configuration
│   ├── images.nix            # Container image loading utilities
│   ├── variants/
│   │   ├── docker.nix        # Docker Compose variant
│   │   ├── minikube.nix      # Minikube variant
│   │   └── k3s.nix           # K3s variant
│   └── tests/
│       ├── default.nix       # Test runner entry point
│       ├── smoke.nix         # Quick smoke tests (all variants)
│       ├── integration.nix   # Full integration tests
│       └── lib.nix           # Test utilities
├── ports.nix                 # Port configuration (unchanged)
└── containers.nix            # Container definitions (unchanged)
```

### Module Composition Pattern

```nix
# nix/microvm/default.nix
{ self, pkgs, ... }:
let
  # Shared configuration builder
  mkMicroVM = { variant, extraModules ? [] }: {
    imports = [
      ./base.nix
      ./images.nix
    ] ++ extraModules;

    _module.args = {
      inherit self variant;
      k8sManifestsPath = ../../k8s;
    };
  };
in
{
  # Export variant configurations
  docker = mkMicroVM {
    variant = "docker";
    extraModules = [ ./variants/docker.nix ];
  };

  minikube = mkMicroVM {
    variant = "minikube";
    extraModules = [ ./variants/minikube.nix ];
  };

  k3s = mkMicroVM {
    variant = "k3s";
    extraModules = [ ./variants/k3s.nix ];
  };
}
```

---

## Variant Specifications

### Common Base (`base.nix`)

Shared across all variants:

| Component | Configuration |
|-----------|---------------|
| Hypervisor | QEMU with user-mode networking |
| Users | root (demo), demo user with sudo |
| SSH | Enabled, password auth for demo |
| Firewall | Disabled for demo access |
| Nix | Flakes enabled |
| Packages | vim, curl, jq, htop, tmux, clickhouse-client |

### Variant: Docker

**Resource Allocation:**
- RAM: 4096 MB
- vCPUs: 2
- Disk: 15 GB

**Components:**
- Docker daemon
- Docker Compose v2

**Container Orchestration:**
```nix
# systemd service that runs docker compose
systemd.services.otel-demo = {
  description = "OTel Demo Stack";
  after = [ "docker.service" "load-images.service" ];
  wantedBy = [ "multi-user.target" ];

  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    WorkingDirectory = "/etc/otel-demo";
  };

  script = ''
    ${pkgs.docker}/bin/docker compose up -d
  '';
};
```

**Generated Compose File:**
- Derived from k8s manifests OR
- Standalone `docker-compose.nix` that generates `docker-compose.yaml`

**Port Forwards:**
| Service | Host Port | Container Port |
|---------|-----------|----------------|
| SSH | 22022 | 22 |
| HyperDX App | 28080 | 8080 |
| HyperDX API | 28000 | 8000 |
| ClickHouse HTTP | 28123 | 8123 |
| ClickHouse Native | 29000 | 9000 |
| FluentBit Metrics | 22020 | 2020 |

### Variant: Minikube

**Resource Allocation:**
- RAM: 8192 MB (VM) / 6144 MB (minikube)
- vCPUs: 4 (VM) / 3 (minikube)
- Disk: 20 GB

**Components:**
- Docker daemon (as minikube driver)
- Minikube
- kubectl
- kustomize

**Container Orchestration:**
```nix
systemd.services.minikube-start = {
  # Start minikube with docker driver
  script = ''
    minikube start --driver=docker --force --cpus=3 --memory=6g
  '';
};

systemd.services.load-images = {
  # Load Nix-built images into minikube
  script = ''
    minikube image load ${images.loggen}
    # ... etc
  '';
};

systemd.services.deploy-manifests = {
  # Apply kustomize manifests
  script = ''
    kubectl apply -k ${k8sManifests}
  '';
};
```

**Port Forwards:**
| Service | Host Port | NodePort |
|---------|-----------|----------|
| SSH | 22022 | 22 |
| HyperDX App | 30808 | 30808 |
| HyperDX API | 30800 | 30800 |

### Variant: K3s

**Resource Allocation:**
- RAM: 6144 MB
- vCPUs: 3
- Disk: 15 GB

**Components:**
- K3s (includes containerd)
- kubectl (via k3s)
- kustomize

**Container Orchestration:**
```nix
services.k3s = {
  enable = true;
  role = "server";
  extraFlags = toString [
    "--disable=traefik"      # We don't need ingress for demo
    "--disable=servicelb"    # Use NodePort instead
  ];
};

systemd.services.load-images = {
  after = [ "k3s.service" ];
  script = ''
    # k3s uses containerd, load via ctr
    k3s ctr images import ${images.loggen}
    # ... etc
  '';
};

systemd.services.deploy-manifests = {
  after = [ "load-images.service" ];
  script = ''
    k3s kubectl apply -k ${k8sManifests}
  '';
};
```

**Port Forwards:**
| Service | Host Port | NodePort |
|---------|-----------|----------|
| SSH | 22022 | 22 |
| HyperDX App | 30808 | 30808 |
| HyperDX API | 30800 | 30800 |

---

## Image Loading Strategy

### Unified Image Loading Module (`images.nix`)

```nix
{ config, lib, pkgs, self, variant, ... }:

let
  packages = self.packages.x86_64-linux;

  images = {
    loggen = packages.loggen-image;
    fluentbit = packages.fluentbit-image;
    clickhouse = packages.clickhouse-image;
    mongodb = packages.mongodb-image;
    hyperdx = packages.hyperdx-image;
  };

  # Variant-specific load command
  loadCommand = {
    docker = image: "${pkgs.docker}/bin/docker load < ${image}";
    minikube = image: "${pkgs.minikube}/bin/minikube image load ${image}";
    k3s = image: "${pkgs.k3s}/bin/k3s ctr images import ${image}";
  }.${variant};

in {
  options.microvm.images = lib.mkOption {
    type = lib.types.attrsOf lib.types.package;
    default = images;
    description = "Container images to load";
  };

  config = {
    # Pass images to other modules
    _module.args.images = images;
    _module.args.loadCommand = loadCommand;
  };
}
```

---

## Testing Strategy

### Test Levels

```
┌─────────────────────────────────────────────────────────────────┐
│ Level 3: Full Integration Tests (CI, ~10-15 min)                │
│ - Boot VM, wait for services, run full pipeline verification    │
├─────────────────────────────────────────────────────────────────┤
│ Level 2: NixOS VM Tests (nix flake check, ~5 min)               │
│ - NixOS test framework, isolated QEMU VMs                       │
├─────────────────────────────────────────────────────────────────┤
│ Level 1: Build Tests (nix build, ~2 min)                        │
│ - Derivations build successfully                                │
├─────────────────────────────────────────────────────────────────┤
│ Level 0: Eval Tests (nix eval, ~10 sec)                         │
│ - Configuration evaluates without errors                        │
└─────────────────────────────────────────────────────────────────┘
```

### Level 0: Evaluation Tests

```nix
# flake.nix checks
checks.x86_64-linux = {
  # Verify all variants evaluate
  eval-docker = pkgs.runCommand "eval-docker" {} ''
    ${lib.getExe pkgs.nix} eval --json \
      ${self}#nixosConfigurations.microvm-docker.config.system.build.toplevel \
      > /dev/null
    touch $out
  '';

  eval-minikube = /* ... */;
  eval-k3s = /* ... */;
};
```

### Level 1: Build Tests

```nix
checks.x86_64-linux = {
  # Verify VM images build
  build-docker = self.nixosConfigurations.microvm-docker.config.system.build.toplevel;
  build-minikube = self.nixosConfigurations.microvm-minikube.config.system.build.toplevel;
  build-k3s = self.nixosConfigurations.microvm-k3s.config.system.build.toplevel;
};
```

### Level 2: NixOS VM Tests

Using `nixos/tests` framework for isolated testing:

```nix
# nix/microvm/tests/smoke.nix
{ pkgs, self, ... }:

let
  makeTest = import (pkgs.path + "/nixos/tests/make-test-python.nix");
in
{
  # Docker variant smoke test
  docker-smoke = makeTest {
    name = "microvm-docker-smoke";

    nodes.machine = { ... }: {
      imports = [ self.nixosModules.microvm-docker ];
      virtualisation.memorySize = 4096;
      virtualisation.cores = 2;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("docker.service")
      machine.wait_for_unit("load-images.service")
      machine.wait_for_unit("otel-demo.service")

      # Verify containers running
      machine.succeed("docker ps | grep loggen")
      machine.succeed("docker ps | grep fluentbit")
      machine.succeed("docker ps | grep clickhouse")
      machine.succeed("docker ps | grep hyperdx")

      # Basic health checks
      machine.succeed("curl -f http://localhost:8080/")  # HyperDX
      machine.succeed("curl -f http://localhost:8123/")  # ClickHouse
    '';
  };

  # K3s variant smoke test
  k3s-smoke = makeTest {
    name = "microvm-k3s-smoke";

    nodes.machine = { ... }: {
      imports = [ self.nixosModules.microvm-k3s ];
      virtualisation.memorySize = 6144;
      virtualisation.cores = 3;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("k3s.service")
      machine.wait_for_unit("load-images.service")
      machine.wait_for_unit("deploy-manifests.service")

      # Wait for pods
      machine.wait_until_succeeds(
        "k3s kubectl -n otel-demo get pods | grep -v Pending | grep -v ContainerCreating",
        timeout=300
      )

      # Verify pods running
      machine.succeed("k3s kubectl -n otel-demo get pods | grep loggen | grep Running")
      machine.succeed("k3s kubectl -n otel-demo get pods | grep clickhouse | grep Running")
    '';
  };

  # Minikube variant (longer timeout due to overhead)
  minikube-smoke = makeTest {
    name = "microvm-minikube-smoke";

    nodes.machine = { ... }: {
      imports = [ self.nixosModules.microvm-minikube ];
      virtualisation.memorySize = 8192;
      virtualisation.cores = 4;
      virtualisation.diskSize = 20480;
    };

    testScript = ''
      machine.start()
      machine.wait_for_unit("minikube-start.service", timeout=600)
      machine.wait_for_unit("deploy-manifests.service", timeout=300)

      # Verify pods
      machine.wait_until_succeeds(
        "kubectl -n otel-demo get pods | grep Running",
        timeout=300
      )
    '';
  };
}
```

### Level 3: Full Integration Tests

End-to-end pipeline verification:

```nix
# nix/microvm/tests/integration.nix
{ pkgs, self, ... }:

let
  makeTest = import (pkgs.path + "/nixos/tests/make-test-python.nix");
in
{
  # Full pipeline test - logs flow from loggen to ClickHouse to HyperDX
  pipeline-integration = makeTest {
    name = "otel-pipeline-integration";

    nodes.machine = { ... }: {
      imports = [ self.nixosModules.microvm-k3s ];  # Use k3s for faster tests
      virtualisation.memorySize = 6144;
      virtualisation.cores = 3;
    };

    testScript = ''
      import json

      machine.start()
      machine.wait_for_unit("k3s.service")
      machine.wait_for_unit("deploy-manifests.service")

      # Wait for all pods ready
      machine.wait_until_succeeds(
        "k3s kubectl -n otel-demo wait --for=condition=Ready pods --all --timeout=300s"
      )

      # 1. Verify loggen is producing logs
      machine.wait_until_succeeds(
        "k3s kubectl -n otel-demo logs deploy/loggen | grep -q 'log entry'",
        timeout=60
      )

      # 2. Verify FluentBit is receiving logs
      machine.succeed(
        "curl -s http://localhost:2020/api/v1/metrics | grep -q 'fluentbit_input_records_total'"
      )

      # 3. Verify ClickHouse has data
      machine.wait_until_succeeds(
        "clickhouse-client --query 'SELECT count() FROM otel.logs' | grep -v '^0$'",
        timeout=120
      )

      # 4. Verify HyperDX API responds
      machine.succeed("curl -f http://localhost:8000/health")

      # 5. Verify HyperDX can query logs
      result = machine.succeed(
        "curl -s http://localhost:8000/api/v1/logs?limit=1"
      )
      logs = json.loads(result)
      assert len(logs) > 0, "HyperDX should return logs"

      # 6. Latency test - measure end-to-end pipeline latency
      machine.succeed("${self.packages.x86_64-linux.measure-latency}/bin/measure-latency")
    '';
  };
}
```

### Test Matrix

| Test | Docker | Minikube | K3s | CI |
|------|--------|----------|-----|-----|
| Eval | ~10s | ~10s | ~10s | Always |
| Build | ~2m | ~3m | ~2m | Always |
| Smoke | ~3m | ~8m | ~4m | PR |
| Integration | ~5m | ~12m | ~6m | Main branch |

---

## Flake Integration

### Updated `flake.nix`

```nix
{
  outputs = { self, nixpkgs, microvm, ... }:
    let
      # ... existing package definitions ...

      # Import microvm module system
      microvmVariants = import ./nix/microvm {
        inherit self;
        inherit (nixpkgs) lib;
      };
    in
    {
      # Existing outputs...

      # NixOS Configurations for MicroVMs
      nixosConfigurations = {
        microvm-docker = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            microvm.nixosModules.microvm
            microvmVariants.docker
          ];
        };

        microvm-minikube = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            microvm.nixosModules.microvm
            microvmVariants.minikube
          ];
        };

        microvm-k3s = nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            microvm.nixosModules.microvm
            microvmVariants.k3s
          ];
        };
      };

      # NixOS Modules (for testing framework)
      nixosModules = {
        microvm-docker = microvmVariants.docker;
        microvm-minikube = microvmVariants.minikube;
        microvm-k3s = microvmVariants.k3s;
      };

      # Checks including VM tests
      checks.x86_64-linux = {
        # Existing checks...

        # Level 0: Eval tests
        eval-microvm-docker = /* ... */;
        eval-microvm-minikube = /* ... */;
        eval-microvm-k3s = /* ... */;

        # Level 1: Build tests (implicit - derivations)

        # Level 2: Smoke tests
        vm-docker-smoke = microvmTests.docker-smoke;
        vm-k3s-smoke = microvmTests.k3s-smoke;
        # Note: minikube-smoke optional due to resource requirements

        # Level 3: Integration (optional, CI only)
        # vm-integration = microvmTests.pipeline-integration;
      };

      # Apps for running variants
      apps.x86_64-linux = {
        # Existing apps...

        microvm-docker = {
          type = "app";
          program = toString (
            self.nixosConfigurations.microvm-docker.config.microvm.declaredRunner
          );
        };

        microvm-minikube = {
          type = "app";
          program = toString (
            self.nixosConfigurations.microvm-minikube.config.microvm.declaredRunner
          );
        };

        microvm-k3s = {
          type = "app";
          program = toString (
            self.nixosConfigurations.microvm-k3s.config.microvm.declaredRunner
          );
        };
      };
    };
}
```

---

## Implementation Phases

### Phase 1: Module Infrastructure (Day 1)

**Tasks:**
1. Create `nix/microvm/` directory structure
2. Extract shared config from current `microvm.nix` into `base.nix`
3. Create `images.nix` with variant-aware image loading
4. Create `default.nix` module composition

**Deliverables:**
- [ ] `nix/microvm/default.nix`
- [ ] `nix/microvm/base.nix`
- [ ] `nix/microvm/images.nix`

**Validation:**
```bash
nix eval .#nixosConfigurations.microvm-docker.config.system.build.toplevel
```

### Phase 2: Docker Variant (Day 1-2)

**Tasks:**
1. Create `variants/docker.nix`
2. Generate docker-compose.yaml from Nix
3. Create systemd services for lifecycle management
4. Test container startup

**Deliverables:**
- [ ] `nix/microvm/variants/docker.nix`
- [ ] `nix/microvm/docker-compose.nix` (compose file generator)

**Validation:**
```bash
nix build .#nixosConfigurations.microvm-docker.config.system.build.toplevel
nix run .#microvm-docker
# SSH in and verify: docker ps
```

### Phase 3: K3s Variant (Day 2)

**Tasks:**
1. Create `variants/k3s.nix`
2. Configure k3s service with appropriate flags
3. Image loading via `k3s ctr`
4. Manifest deployment via `k3s kubectl`

**Deliverables:**
- [ ] `nix/microvm/variants/k3s.nix`

**Validation:**
```bash
nix build .#nixosConfigurations.microvm-k3s.config.system.build.toplevel
nix run .#microvm-k3s
# SSH in and verify: k3s kubectl get pods -A
```

### Phase 4: Minikube Variant (Day 2-3)

**Tasks:**
1. Create `variants/minikube.nix` (refactor from current)
2. Fix Docker path issues
3. Optimize resource allocation
4. Test full deployment

**Deliverables:**
- [ ] `nix/microvm/variants/minikube.nix`

**Validation:**
```bash
nix build .#nixosConfigurations.microvm-minikube.config.system.build.toplevel
nix run .#microvm-minikube
# SSH in and verify: kubectl get pods -n otel-demo
```

### Phase 5: Test Infrastructure (Day 3)

**Tasks:**
1. Create test utilities in `tests/lib.nix`
2. Implement smoke tests for all variants
3. Implement integration test
4. Add tests to flake checks

**Deliverables:**
- [ ] `nix/microvm/tests/default.nix`
- [ ] `nix/microvm/tests/lib.nix`
- [ ] `nix/microvm/tests/smoke.nix`
- [ ] `nix/microvm/tests/integration.nix`

**Validation:**
```bash
nix flake check  # Runs all checks including VM tests
```

### Phase 6: Documentation & Cleanup (Day 3-4)

**Tasks:**
1. Update README with variant usage
2. Remove old `nix/microvm.nix`
3. Update any scripts referencing old structure
4. Final review and testing

**Deliverables:**
- [ ] Updated README.md
- [ ] Removed deprecated files
- [ ] All tests passing

---

## Resource Requirements Summary

| Variant | VM RAM | VM CPUs | Disk | Startup Time |
|---------|--------|---------|------|--------------|
| Docker | 4 GB | 2 | 15 GB | ~30s |
| K3s | 6 GB | 3 | 15 GB | ~60s |
| Minikube | 8 GB | 4 | 20 GB | ~180s |

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| K3s containerd image format incompatibility | Test OCI tarball loading early; may need skopeo conversion |
| Minikube nested virtualization issues | Document as "requires more resources"; suggest K3s for constrained environments |
| Test flakiness due to timing | Use `wait_until_succeeds` with appropriate timeouts |
| CI resource constraints | Run minikube tests only on main branch; docker/k3s on PRs |

---

## Success Criteria

1. **All three variants build successfully** - `nix build` passes
2. **All variants boot and run workloads** - containers/pods reach Running state
3. **Pipeline functions end-to-end** - logs flow from loggen to ClickHouse
4. **Tests pass in CI** - `nix flake check` succeeds
5. **Documentation complete** - Users can run any variant with single command

---

## Commands Reference

```bash
# Build specific variant
nix build .#nixosConfigurations.microvm-docker.config.system.build.toplevel
nix build .#nixosConfigurations.microvm-k3s.config.system.build.toplevel
nix build .#nixosConfigurations.microvm-minikube.config.system.build.toplevel

# Run specific variant
nix run .#microvm-docker
nix run .#microvm-k3s
nix run .#microvm-minikube

# Run tests
nix flake check                           # All checks
nix build .#checks.x86_64-linux.vm-docker-smoke   # Specific test

# SSH into running VM
ssh -p 22022 demo@localhost  # password: demo
```
