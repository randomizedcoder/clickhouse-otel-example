# HyperDX Dependencies Analysis

**Created:** 2026-02-23

## Problem

The HyperDX container image is 3.12 GB (uncompressed) / 698 MB (compressed), which is excessively large for a Node.js application.

## Root Cause

We're copying the entire root `node_modules` (1.3 GB) which contains:
- All development dependencies (typescript, eslint, prettier, nx, etc.)
- Duplicate packages already included in Next.js standalone build

## Current Size Breakdown

```
Total HyperDX package: 1.3 GB

├── node_modules/     1.3 GB  ← THE PROBLEM
│   ├── next/           156 MB  (duplicated in standalone!)
│   ├── @next/          110 MB  (duplicated in standalone!)
│   ├── node-sql-parser/ 86 MB
│   ├── @tabler/         85 MB  (icons)
│   ├── typescript/      23 MB  (dev only!)
│   ├── @nx/             19 MB  (dev only!)
│   ├── eslint-*         29 MB  (dev only!)
│   ├── @changesets/     15 MB  (dev only!)
│   ├── @types/          12 MB  (dev only!)
│   ├── nx/              12 MB  (dev only!)
│   ├── prettier/        7.5 MB (dev only!)
│   └── ... 1350+ more packages
│
└── packages/          39 MB   ← WHAT WE ACTUALLY NEED
    ├── app/           135 MB  (Next.js standalone with its own node_modules)
    ├── api/           2.3 MB  (compiled TypeScript)
    └── common-utils/  1.1 MB
```

## What Each Component Actually Needs

### Next.js App (packages/app)

The Next.js standalone build is **self-contained**. It includes:
- Bundled application code
- Its own `node_modules/` (107 MB) with only production dependencies
- Static assets

**Required:** Just the standalone output directory. No root node_modules needed.

### API (packages/api)

The API is compiled TypeScript that needs runtime dependencies. Key imports:

```javascript
// External packages needed at runtime
require("tslib")
require("@hyperdx/node-opentelemetry/build/src/metrics")
require("@opentelemetry/host-metrics")
require("@opentelemetry/sdk-metrics")
require("serialize-error")
require("tsconfig-paths/register")  // for path alias resolution

// Plus many more for Express, MongoDB, ClickHouse, etc.
```

**Required production dependencies for API:**
- `tslib`
- `@hyperdx/node-opentelemetry`
- `@opentelemetry/*` packages
- `serialize-error`
- `tsconfig-paths`
- `express` and middleware
- `mongoose` / `mongodb`
- `@clickhouse/client`
- `connect-mongo`
- `winston` / logging
- `cors`, `helmet`, `compression`

### Common-Utils (packages/common-utils)

Pre-built utility library. Bundled by other packages, minimal runtime deps.

## Solution Options

### Option 1: Prune node_modules (Recommended)

Only copy production dependencies to the container:

```nix
# In installPhase, instead of:
cp -r node_modules $out/app/

# Do:
# 1. Don't copy root node_modules at all
# 2. Next.js standalone is already self-contained
# 3. For API, copy only production deps or use yarn workspaces focus
```

### Option 2: Use yarn workspaces focus

```bash
# Install only production deps for API
yarn workspaces focus @hyperdx/api --production
```

### Option 3: Bundle API with esbuild/webpack

Bundle the API into a single file with all dependencies included, similar to Next.js standalone.

## Packages to EXCLUDE (dev only)

These should NOT be in production:

| Package | Size | Reason |
|---------|------|--------|
| `typescript` | 23 MB | Compile-time only |
| `@nx/*`, `nx` | 31 MB | Build tooling |
| `eslint*` | 29 MB | Linting |
| `@changesets/*` | 15 MB | Release tooling |
| `@types/*` | 12 MB | TypeScript types |
| `prettier` | 7.5 MB | Formatting |
| `jest`, `@jest/*` | ~10 MB | Testing |
| `@testing-library/*` | ~5 MB | Testing |
| `nodemon` | ~2 MB | Dev server |
| `ts-node` | ~2 MB | Dev only |

## Packages to INCLUDE (production)

### For API runtime:

| Package | Purpose |
|---------|---------|
| `tslib` | TypeScript runtime helpers |
| `tsconfig-paths` | Path alias resolution |
| `@opentelemetry/*` | Observability |
| `@hyperdx/node-opentelemetry` | HyperDX integration |
| `express` | Web server |
| `mongoose` | MongoDB ODM |
| `@clickhouse/client` | ClickHouse queries |
| `connect-mongo` | Session storage |
| `serialize-error` | Error handling |
| `winston` | Logging |
| `cors`, `helmet`, `compression` | Middleware |
| `jsonwebtoken` | Auth |
| `bcrypt` | Password hashing |
| `node-cron` | Task scheduling |

### For Next.js App:

**None needed** - standalone build is self-contained.

## Size After Fix (Implemented 2026-02-23)

| Metric | Before | After | Reduction |
|--------|--------|-------|-----------|
| Compressed image | 698 MB | 406 MB | 42% |
| Uncompressed (Docker) | 3.12 GB | 1.81 GB | 42% |
| node_modules | 1.3 GB | 598 MB | 54% |

### Packages Removed

The following packages are now excluded from the production image:

**Dev/Build tools (~150 MB):**
- `typescript`, `ts-node`, `tsup`
- `eslint`, `eslint-*`, `@typescript-eslint`
- `prettier`, `stylelint`
- `nx`, `@nx`, `@nrwl`
- `jest`, `@jest`, `jest-*`, `ts-jest`
- `@testing-library`, `vitest`, `@vitest`
- `playwright`, `playwright-core`, `jsdom`
- `chromatic`, `storybook`, `@storybook`
- `husky`, `lint-staged`, `knip`
- `@changesets`, `@types`

**Duplicated in Next.js standalone (~300 MB):**
- `next`, `@next`
- `react`, `react-dom`
- `@babel`, `webpack`, `@swc`, `esbuild`, `@esbuild`
- `postcss`, `autoprefixer`, `tailwindcss`, `sass`
- `core-js`, `core-js-pure`

**Frontend packages (bundled in standalone):**
- `@tabler`, `@mantine`, `@tanstack`, `@hookform`
- `@radix-ui`, `@emotion`, `styled-components`
- `framer-motion`, `recharts`, `rrweb`, `d3`, `d3-*`

## Implementation Steps

1. **Modify `nix/hyperdx.nix`**:
   - Remove `cp -r node_modules $out/app/`
   - Next.js standalone already works without it
   - API needs a different approach (see below)

2. **For API dependencies**, choose one:
   - a) Create a separate `yarn install --production` for API
   - b) Bundle API with esbuild
   - c) Manually list and copy required packages

3. **Update container to use standalone paths correctly**

4. **Test that all runtime imports resolve**

## Notes

- The Next.js standalone (107 MB internal node_modules) is correctly sized
- The API's production deps should be ~50-100 MB max
- Total image should be under 300 MB compressed, ~500 MB uncompressed
- **MongoDB** is now included as a separate Nix-built container (~500 MB) for session storage
