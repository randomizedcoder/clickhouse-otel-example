# Claude Code Project Context

## Project Overview

This is a **ClickHouse OpenTelemetry Pipeline Demo** - a complete observability stack built entirely with Nix for reproducible builds. The pipeline demonstrates collecting structured JSON logs, transforming them to OpenTelemetry format, storing in ClickHouse, and visualizing with HyperDX.

## Technology Stack

- **Go 1.26** - Application code with uber-go/zap logging
- **Nix Flakes** - Reproducible builds for all components
- **Yarn Berry (v4)** - For HyperDX Node.js dependencies
- **Kubernetes** - Deployment target (Minikube)
- **MicroVM** - Isolated testing environment

## Key Files

| File | Purpose |
|------|---------|
| `flake.nix` | Main Nix flake with all package outputs |
| `nix/ports.nix` | **Centralized port configuration** - all ports defined here |
| `nix/go-app.nix` | Go application build (uses Go 1.26) |
| `nix/hyperdx.nix` | HyperDX built from source with yarn-berry |
| `nix/containers.nix` | All OCI container image definitions |
| `DESIGN.md` | Comprehensive design document |
| `IMPLEMENTATION_LOG.md` | Implementation progress and decisions |

## Coding Standards

### Go Code
- Use `uber-go/zap` for all logging
- CLI flags with environment variable overrides (env vars take precedence)
- Place business logic in `internal/` packages
- Entry point in `cmd/loggen/main.go`
- Full test coverage including race tests (`go test -race`)

### Nix Code
- Use nixpkgs-unstable
- Prefer `callPackage` pattern
- Centralize configuration (see `nix/ports.nix` for port constants)
- OCI images must be standalone (no /nix/store bind mounts)
- Use `yarn-berry` infrastructure for Node.js projects with Yarn 4

### Kubernetes
- All resources in `otel-demo` namespace
- Use kustomization.yaml for deployment
- Include health probes on all deployments
- Use ConfigMaps for configuration

## Port Configuration

**IMPORTANT:** All ports are defined in `nix/ports.nix`. When adding or modifying ports:
1. Add the port to `nix/ports.nix`
2. Reference it using `ports.services.<name>` or `ports.hostForwards.<name>`
3. Update containers.nix and microvm.nix to use the variable

## Building

```bash
# Build all container images
nix build .#all-images

# Build individual components
nix build .#loggen          # Go binary
nix build .#hyperdx         # HyperDX package
nix build .#loggen-image    # OCI image

# Run tests
nix run .#test
nix run .#test-race

# Development shell
nix develop
```

## Common Tasks

### Adding a New Port
1. Edit `nix/ports.nix` - add to `services` and optionally `hostForwards`
2. Update `nix/containers.nix` if container needs the port
3. Update `nix/microvm.nix` if port forwarding needed
4. Update Kubernetes manifests in `k8s/`

### Updating HyperDX
1. Get new GitHub hash: `nix-prefetch-github hyperdxio hyperdx --rev main`
2. Update `rev` and `hash` in `nix/hyperdx.nix`
3. Regenerate missing-hashes: Run `yarn-berry-fetcher missing-hashes` on the new yarn.lock
4. Update `offlineCache` hash (use `lib.fakeHash`, build, copy the "got:" hash)

### Updating Go Dependencies
1. Update `go.mod` and `go.sum`
2. Update `vendorHash` in `nix/go-app.nix` (use `lib.fakeHash` to get correct hash)

## Architecture Decisions

1. **HyperDX from source** - Built with Nix rather than Docker pull for reproducibility and layer optimization
2. **Local fonts** - Google Fonts replaced with nixpkgs fonts (inter, ibm-plex, roboto, roboto-mono) to avoid network access during build
3. **Centralized ports** - All ports in `nix/ports.nix` to avoid port conflicts and ensure consistency
4. **Non-standard host ports** - Using 2XXXX prefix (e.g., 28080) to avoid conflicts with local services
5. **FluentBit from nixpkgs** - Uses the nixpkgs `fluent-bit` package rather than building from source

## Testing

- Go unit tests: `nix run .#test`
- Go race tests: `nix run .#test-race`
- Nix checks: `nix flake check`
- Integration: Deploy to Minikube and verify full pipeline

## Troubleshooting

### HyperDX Build Fails
- Check if yarn.lock changed - may need to update `offlineCache` hash
- Check if native packages changed - may need to regenerate `hyperdx-missing-hashes.json`
- Font issues usually mean the postPatch isn't correctly patching fonts.ts

### Container Won't Start
- Check the start script paths in `nix/hyperdx.nix` or `nix/containers.nix`
- For HyperDX, the Next.js standalone creates nested `packages/app/` structure

### Port Conflicts
- All ports should be defined in `nix/ports.nix`
- Host forwards use 2XXXX prefix to avoid conflicts
