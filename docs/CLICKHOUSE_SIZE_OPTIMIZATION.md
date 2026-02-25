# ClickHouse Size Optimization Design Document

This document analyzes how to reduce the ClickHouse container/binary size for the clickhouse-otel-example logging pipeline project.

## Executive Summary

The current "fully featured" ClickHouse build includes many components not needed for this project (Kafka engine, S3 storage, PostgreSQL/MySQL integrations, HDFS, gRPC, etc.). By creating a minimal Nix derivation that disables unused features at compile time, we can significantly reduce the binary and container size.

**Key finding:** This project only uses MergeTree/SummingMergeTree table engines, HTTP interface, JSONEachRow format, and basic aggregation functions - a small subset of ClickHouse's capabilities.

---

## 1. Features Required for This Project

Based on analysis of the project's SQL schemas, configurations, and integrations:

### 1.1 Table Engines (Required)

| Engine | Usage |
|--------|-------|
| **MergeTree** | Primary `otel_logs` table for log storage |
| **SummingMergeTree** | `otel_logs_hourly` materialized view for pre-aggregation |

**Not needed:** Kafka, MySQL, PostgreSQL, S3, HDFS, RocksDB, Cassandra, MongoDB, Hive, ReplicatedMergeTree (single-node deployment)

### 1.2 Data Types (Required)

- `DateTime64(9)` - Nanosecond precision timestamps
- `String`, `LowCardinality(String)` - Text fields
- `UInt32`, `Int32`, `UInt64` - Integers
- `Map(LowCardinality(String), String)` - OTEL attributes

### 1.3 Compression Codecs (Required)

- **ZSTD** - Primary compression (ZSTD level 1)
- **Delta** - For timestamps and counters
- **LZ4** - Default ClickHouse compression (built-in)

**Not needed:** Brotli, BZip2, Snappy (optional)

### 1.4 Indexes (Required)

- **Bloom filter** (`bloom_filter`) - TraceId lookups
- **Set index** (`set`) - SeverityText, ServiceName filtering
- **MinMax index** - Range queries on RandomNumber
- **Token bloom filter** (`tokenbf_v1`) - Full-text search on Body

### 1.5 Interfaces (Required)

- **HTTP interface** (port 8123) - FluentBit data ingestion
- **Native protocol** (port 9000) - clickhouse-client CLI access

**Not needed:** gRPC, MySQL wire protocol, PostgreSQL wire protocol

### 1.6 Data Formats (Required)

- **JSONEachRow** - FluentBit sends logs in this format (supports batch insertion)
- Basic output formats (TabSeparated, Pretty)

**Batch JSON Insertion:** JSONEachRow natively supports batch inserts - simply send multiple JSON objects, one per line:

```bash
curl -X POST 'http://localhost:8123/?query=INSERT INTO otel_logs FORMAT JSONEachRow' \
  --data-binary @- << 'EOF'
{"Timestamp":"2024-01-01 00:00:00","Body":"log 1"}
{"Timestamp":"2024-01-01 00:00:01","Body":"log 2"}
{"Timestamp":"2024-01-01 00:00:02","Body":"log 3"}
EOF
```

This is exactly how FluentBit sends data. No additional formats needed.

**Not needed:** Avro, Parquet, Arrow, ORC, Cap'n Proto, MessagePack, Protobuf

### 1.7 Query Features (Required)

- Basic aggregations: `count()`, `avg()`, `min()`, `max()`, `sum()`
- Time functions: `toDate()`, `toDateTime()`, `toStartOfMinute()`, `toStartOfHour()`
- GROUP BY, ORDER BY, WHERE, LIMIT
- Materialized views

**Not needed:** Machine learning functions, vector search, NLP, geospatial (H3, S2)

### 1.8 Summary: Minimal Feature Set

```
Core Engines:      MergeTree, SummingMergeTree, MaterializedView
Interfaces:        HTTP, Native protocol
Formats:           JSONEachRow, TabSeparated
Compression:       ZSTD, LZ4, Delta codec
Authentication:    Basic (default user)
```

---

## 2. ClickHouse Compile-Time Feature Flags

The ClickHouse CMake build system provides extensive control over which features are compiled in.

### 2.1 Master Control Flag

```cmake
-DENABLE_LIBRARIES=OFF
```

This single flag disables **all** optional external libraries, creating a minimal baseline build. Individual features can then be selectively re-enabled.

### 2.2 Features to DISABLE (Not Needed)

| CMake Flag | Feature | Size Impact |
|------------|---------|-------------|
| `-DENABLE_KAFKA=OFF` | Kafka table engine | Large (librdkafka) |
| `-DENABLE_AMQPCPP=OFF` | RabbitMQ support | Medium |
| `-DENABLE_NATS=OFF` | NATS support | Medium |
| `-DENABLE_MYSQL=OFF` | MySQL table engine | Large |
| `-DENABLE_LIBPQXX=OFF` | PostgreSQL support | Large |
| `-DENABLE_SQLITE=OFF` | SQLite support | Small |
| `-DENABLE_ROCKSDB=OFF` | RocksDB engine | Large |
| `-DENABLE_CASSANDRA=OFF` | Cassandra support | Large |
| `-DENABLE_MONGODB=OFF` | MongoDB support | Medium |
| `-DENABLE_HIVE=OFF` | Hive metastore | Medium |
| `-DENABLE_AWS_S3=OFF` | S3 storage | Large (AWS SDK) |
| `-DENABLE_AZURE_BLOB_STORAGE=OFF` | Azure Blob | Large |
| `-DENABLE_GOOGLE_CLOUD_CPP=OFF` | GCS support | Large |
| `-DENABLE_HDFS=OFF` | HDFS support | Large |
| `-DENABLE_GRPC=OFF` | gRPC interface | Large |
| `-DENABLE_PARQUET=OFF` | Parquet format | Large (Arrow) |
| `-DENABLE_ARROW_FLIGHT=OFF` | Arrow Flight | Large |
| `-DENABLE_AVRO=OFF` | Avro format | Medium |
| `-DENABLE_CAPNP=OFF` | Cap'n Proto | Medium |
| `-DENABLE_PROTOBUF=OFF` | Protocol Buffers | Medium |
| `-DENABLE_MSGPACK=OFF` | MessagePack | Small |
| `-DENABLE_H3=OFF` | H3 geo indexing | Medium |
| `-DENABLE_S2_GEOMETRY=OFF` | S2 geometry | Medium |
| `-DENABLE_NLP=OFF` | NLP functions | Medium |
| `-DENABLE_VECTORSCAN=OFF` | Regex engine | Medium |
| `-DENABLE_USEARCH=OFF` | Vector search | Medium |
| `-DENABLE_EMBEDDED_COMPILER=OFF` | JIT (LLVM) | Very Large |
| `-DENABLE_DWARF_PARSER=OFF` | DWARF support | Medium |
| `-DENABLE_LDAP=OFF` | LDAP auth | Medium |
| `-DENABLE_SSH=OFF` | SSH support | Medium |
| `-DENABLE_PRQL=OFF` | PRQL language | Small |
| `-DENABLE_RUST=OFF` | Rust components | Medium |

### 2.3 LLVM JIT Compiler Trade-offs

The embedded LLVM compiler (`ENABLE_EMBEDDED_COMPILER`) provides runtime JIT compilation of queries. This is one of the largest size contributors (~200-300 MB).

**What JIT provides:**

| With JIT (ON) | Without JIT (OFF) |
|---------------|-------------------|
| Complex expressions compiled to native code | Interpreted execution |
| ~2-5x faster for heavy computations | Slightly slower for math-heavy queries |
| First query has compilation overhead | Consistent query latency |
| +200-300 MB binary size | Smaller binary |

**What you lose without JIT:**

1. **Slower aggregations on computed expressions** - queries like:
   ```sql
   SELECT sum(a * b + sqrt(c)) FROM huge_table
   ```
   Run faster with JIT because the expression `a * b + sqrt(c)` gets compiled to native code.

2. **Slower complex WHERE clauses** - expressions in filters benefit from JIT.

**What's unaffected without JIT:**

- Simple aggregations (`count()`, `sum(column)`, `avg(column)`)
- Index lookups and scans
- Data insertion performance
- JOIN operations (the join logic itself)
- String operations

**Recommendation for this project:**

The OTEL logging queries are straightforward:
```sql
SELECT count() FROM otel_logs WHERE ServiceName = 'x'
SELECT toStartOfHour(Timestamp), count() FROM otel_logs GROUP BY 1
```

These don't benefit significantly from JIT. **Disable it** - the 200-300 MB savings is worth it for a logging pipeline where queries are simple aggregations and filters.

### 2.4 Features to KEEP Enabled

| Feature | Required For |
|---------|--------------|
| HTTP interface | FluentBit integration |
| Native protocol | clickhouse-client |
| MergeTree family | Core table engine |
| ZSTD compression | Data compression |
| LZ4 compression | Default compression |
| JSONEachRow | Data ingestion format |
| Basic SQL | Query execution |
| ICU | Unicode support (optional but useful) |

### 2.5 Build Optimization Flags

```cmake
# Size optimization
-DCMAKE_BUILD_TYPE=MinSizeRel
-DSPLIT_DEBUG_SYMBOLS=ON
-DBUILD_STRIPPED_BINARY=ON

# Disable development features
-DENABLE_TESTS=OFF
-DENABLE_EXAMPLES=OFF
-DENABLE_BENCHMARKS=OFF
-DENABLE_FUZZING=OFF

# Disable standalone keeper (not using distributed setup)
-DBUILD_STANDALONE_KEEPER=OFF
-DENABLE_CLICKHOUSE_KEEPER=OFF
```

---

## 3. Current nixpkgs Derivation Analysis

### 3.1 Location and Structure

```
/home/das/Downloads/nixpkgs/pkgs/by-name/cl/clickhouse/
├── generic.nix    # Core derivation logic
├── package.nix    # Stable version (26.1.2.11)
├── lts.nix        # LTS version (25.8.15.35)
└── update.sh      # Version update script
```

### 3.2 Current CMake Flags

The nixpkgs derivation currently passes minimal CMake flags:

```nix
cmakeFlags = [
  "-DENABLE_CHDIG=OFF"
  "-DENABLE_TESTS=OFF"
  "-DENABLE_DELTA_KERNEL_RS=0"
  "-DCOMPILER_CACHE=disabled"
];
```

**This means the current build includes ALL optional features** - Kafka, S3, PostgreSQL, MySQL, gRPC, Parquet, etc.

### 3.3 Existing Size Optimizations

The derivation already includes some size optimizations:

1. **Source cleanup** - Removes test directories, documentation, unused sysroot files
2. **Reference stripping** - Uses `removeReferencesTo` to strip compiler references
3. **Config minimization** - Strips logging config in postInstall

### 3.4 Customization Methods

1. **`.override`** - Change input parameters (e.g., `rustSupport`)
2. **`.overrideAttrs`** - Modify derivation attributes (cmakeFlags, etc.)
3. **Custom derivation** - Fork generic.nix with additional parameters

---

## 4. Recommended Implementation

### 4.1 Approach: Create a Minimal ClickHouse Overlay

Create a custom Nix derivation that extends the nixpkgs ClickHouse with additional CMake flags to disable unused features.

### 4.2 Implementation

Create `nix/clickhouse-minimal.nix`:

```nix
{ pkgs, ... }:

let
  # Minimal ClickHouse build for OTEL logging pipeline
  # Disables unused features to reduce binary/container size
  clickhouse-minimal = pkgs.clickhouse.overrideAttrs (oldAttrs: {
    pname = "clickhouse-minimal";

    cmakeFlags = oldAttrs.cmakeFlags ++ [
      # ============================================
      # DISABLE EXTERNAL DATABASE INTEGRATIONS
      # ============================================
      "-DENABLE_KAFKA=OFF"              # Kafka table engine
      "-DENABLE_AMQPCPP=OFF"            # RabbitMQ
      "-DENABLE_NATS=OFF"               # NATS
      "-DENABLE_MYSQL=OFF"              # MySQL engine
      "-DENABLE_LIBPQXX=OFF"            # PostgreSQL
      "-DENABLE_SQLITE=OFF"             # SQLite
      "-DENABLE_ROCKSDB=OFF"            # RocksDB engine
      "-DENABLE_CASSANDRA=OFF"          # Cassandra
      "-DENABLE_MONGODB=OFF"            # MongoDB
      "-DENABLE_HIVE=OFF"               # Hive metastore

      # ============================================
      # DISABLE CLOUD STORAGE
      # ============================================
      "-DENABLE_AWS_S3=OFF"             # AWS S3
      "-DENABLE_AZURE_BLOB_STORAGE=OFF" # Azure Blob
      "-DENABLE_GOOGLE_CLOUD_CPP=OFF"   # Google Cloud Storage
      "-DENABLE_HDFS=OFF"               # Hadoop HDFS

      # ============================================
      # DISABLE UNUSED DATA FORMATS
      # ============================================
      "-DENABLE_PARQUET=OFF"            # Parquet (includes Arrow)
      "-DENABLE_ARROW_FLIGHT=OFF"       # Arrow Flight
      "-DENABLE_AVRO=OFF"               # Apache Avro
      "-DENABLE_CAPNP=OFF"              # Cap'n Proto
      "-DENABLE_PROTOBUF=OFF"           # Protocol Buffers
      "-DENABLE_MSGPACK=OFF"            # MessagePack

      # ============================================
      # DISABLE UNUSED INTERFACES
      # ============================================
      "-DENABLE_GRPC=OFF"               # gRPC interface

      # ============================================
      # DISABLE ADVANCED FEATURES
      # ============================================
      "-DENABLE_EMBEDDED_COMPILER=OFF"  # JIT compilation (LLVM)
      "-DENABLE_DWARF_PARSER=OFF"       # DWARF debugging
      "-DENABLE_H3=OFF"                 # H3 geospatial
      "-DENABLE_S2_GEOMETRY=OFF"        # S2 geometry
      "-DENABLE_NLP=OFF"                # NLP functions
      "-DENABLE_VECTORSCAN=OFF"         # Regex engine
      "-DENABLE_USEARCH=OFF"            # Vector search
      "-DENABLE_DATASKETCHES=OFF"       # Data sketches
      "-DENABLE_SIMSIMD=OFF"            # SIMD similarity

      # ============================================
      # DISABLE AUTH FEATURES NOT NEEDED
      # ============================================
      "-DENABLE_LDAP=OFF"               # LDAP authentication
      "-DENABLE_SSH=OFF"                # SSH support
      "-DENABLE_JWT_CPP=OFF"            # JWT tokens

      # ============================================
      # DISABLE DEVELOPMENT/OPTIONAL
      # ============================================
      "-DENABLE_PRQL=OFF"               # PRQL language
      "-DENABLE_RUST=OFF"               # Rust components
      "-DENABLE_NURAFT=OFF"             # Raft consensus (for Keeper)
      "-DENABLE_CLICKHOUSE_KEEPER=OFF"  # Keeper functionality

      # ============================================
      # BUILD OPTIMIZATIONS
      # ============================================
      "-DBUILD_STANDALONE_KEEPER=OFF"
      "-DENABLE_EXAMPLES=OFF"
      "-DENABLE_BENCHMARKS=OFF"
    ];

    meta = oldAttrs.meta // {
      description = "Minimal ClickHouse build for OTEL logging pipeline";
    };
  });
in
  clickhouse-minimal
```

### 4.3 Integration with Project Flake

Update `flake.nix` to use the minimal build:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    # ... other inputs
  };

  outputs = { self, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      clickhouse-minimal = import ./nix/clickhouse-minimal.nix { inherit pkgs; };
    in
    {
      packages.${system} = {
        clickhouse = clickhouse-minimal;
        # ... other packages
      };

      # Use in container builds
      dockerImages.clickhouse = pkgs.dockerTools.buildImage {
        name = "clickhouse-minimal";
        tag = "latest";
        copyToRoot = pkgs.buildEnv {
          name = "image-root";
          paths = [ clickhouse-minimal ];
        };
        config = {
          Cmd = [ "${clickhouse-minimal}/bin/clickhouse" "server" ];
          ExposedPorts = {
            "8123/tcp" = {};
            "9000/tcp" = {};
          };
        };
      };
    };
}
```

### 4.4 Actual Size Reduction (Measured)

Build completed and tested. Here are the actual measured results:

| Metric | Minimal | Full (nixpkgs) | Savings |
|--------|---------|----------------|---------|
| **Binary size** | 535 MB | 748 MB | **213 MB (28%)** |
| **Nix closure** | 1.1 GiB | 1.3 GiB | **~200 MB (15%)** |
| **Container image** | 293 MB | 355 MB | **62 MB (17%)** |

**Note:** The container image savings are smaller than binary savings because:
- Container images are compressed (gzip)
- Both images share common base layers (glibc, etc.)
- The most space-intensive disabled features (LLVM JIT, cloud SDKs) contribute more to uncompressed size

### 4.5 Verification Steps

After building, verify the minimal build works:

```bash
# Build the minimal ClickHouse
nix build .#clickhouse

# Verify it starts
./result/bin/clickhouse server --config-file=config.xml &

# Test HTTP interface
curl http://localhost:8123/ping

# Test JSONEachRow ingestion
echo '{"Timestamp":"2024-01-01 00:00:00","Body":"test"}' | \
  curl -X POST 'http://localhost:8123/?query=INSERT%20INTO%20test%20FORMAT%20JSONEachRow' \
       -H 'Content-Type: application/json' \
       --data-binary @-

# Verify basic queries
clickhouse-client --query "SELECT 1"
clickhouse-client --query "SELECT count() FROM system.functions"

# Check binary size
ls -lh ./result/bin/clickhouse

# Check which features are compiled in
clickhouse-client --query "SELECT * FROM system.build_options WHERE name LIKE 'USE_%'"
```

---

## 5. Alternative Approaches

### 5.1 Use ENABLE_LIBRARIES=OFF

More aggressive approach using the master disable flag:

```nix
cmakeFlags = [
  "-DENABLE_LIBRARIES=OFF"
  # Then selectively re-enable what we need
  "-DENABLE_ICU=ON"           # Unicode support
  "-DENABLE_BROTLI=ON"        # Compression option
  # ... other needed features
];
```

**Pros:** Smallest possible binary
**Cons:** Risk of missing subtle dependencies; requires thorough testing

### 5.2 Alpine-Based Container with musl

Build ClickHouse with musl libc instead of glibc for smaller runtime:

```nix
pkgs.pkgsStatic.clickhouse.overrideAttrs (oldAttrs: {
  cmakeFlags = oldAttrs.cmakeFlags ++ [
    # minimal flags as above
  ];
});
```

**Pros:** Even smaller containers
**Cons:** Potential compatibility issues with musl

### 5.3 Use Pre-built Minimal Docker Image

ClickHouse provides official minimal images:

```yaml
# docker-compose.yml
services:
  clickhouse:
    image: clickhouse/clickhouse-server:latest-alpine
```

**Pros:** No custom build needed
**Cons:** Less control over exact features; may still include unused components

---

## 6. Risk Assessment

### 6.1 Low Risk

- Disabling Kafka, S3, PostgreSQL, MySQL, HDFS - clearly not used
- Disabling gRPC - only HTTP interface is used
- Disabling Parquet/Avro/Arrow - only JSONEachRow is used
- Disabling LLVM JIT - basic queries don't need it

### 6.2 Medium Risk

- Disabling Keeper - single-node deployment, but needed if adding replicas later
- Disabling Rust components - may affect some newer features

### 6.3 Mitigation

- Thoroughly test the minimal build with the project's actual workload
- Document which features are disabled for future reference
- Keep the full ClickHouse as a fallback option

---

## 7. Implementation Checklist

- [x] Create `nix/clickhouse-minimal.nix` with disabled features
- [x] Update `nix/clickhouse.nix` to accept `useMinimal` parameter
- [x] Update `flake.nix` to expose minimal build packages
- [x] Build and test minimal ClickHouse
- [x] Verify all project functionality works:
  - [x] MergeTree table operations
  - [x] SummingMergeTree (for materialized views)
  - [x] JSONEachRow INSERT and SELECT (FluentBit integration)
  - [x] ZSTD + Delta compression codecs
  - [x] Bloom filter indexes
  - [x] Time functions (toDate, toStartOfHour, etc.)
  - [x] Basic aggregations (count, GROUP BY)
- [x] Measure size reduction (binary and container)
- [x] Update project documentation
- [ ] Create CI test for minimal build
- [ ] Test with full pipeline (FluentBit → ClickHouse → HyperDX)

---

## 8. References

- [ClickHouse Build Documentation](https://clickhouse.com/docs/en/development/build)
- [ClickHouse CMakeLists.txt](https://github.com/ClickHouse/ClickHouse/blob/master/CMakeLists.txt)
- [nixpkgs ClickHouse derivation](https://github.com/NixOS/nixpkgs/tree/master/pkgs/by-name/cl/clickhouse)
- Project files:
  - `k8s/clickhouse/init.sql` - SQL schema
  - `k8s/clickhouse/configmap.yaml` - Server configuration
  - `nix/fluentbit.nix` - FluentBit integration
