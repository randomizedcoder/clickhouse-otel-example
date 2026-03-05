# Minimal ClickHouse build for OTEL logging pipeline
# Disables unused features to significantly reduce binary/container size
#
# See docs/CLICKHOUSE_SIZE_OPTIMIZATION.md for detailed analysis
{ pkgs }:

pkgs.clickhouse.overrideAttrs (oldAttrs: {
  pname = "clickhouse-minimal";

  cmakeFlags = (oldAttrs.cmakeFlags or [ ]) ++ [
    # ============================================
    # DISABLE EXTERNAL DATABASE INTEGRATIONS
    # (Kafka enabled for GDP integration)
    # ============================================
    # "-DENABLE_KAFKA=OFF" # Kafka table engine - ENABLED for GDP
    "-DENABLE_AMQPCPP=OFF" # RabbitMQ
    "-DENABLE_NATS=OFF" # NATS
    "-DENABLE_MYSQL=OFF" # MySQL engine
    "-DENABLE_LIBPQXX=OFF" # PostgreSQL
    "-DENABLE_SQLITE=OFF" # SQLite
    "-DENABLE_ROCKSDB=OFF" # RocksDB engine
    "-DENABLE_CASSANDRA=OFF" # Cassandra
    "-DENABLE_MONGODB=OFF" # MongoDB
    "-DENABLE_HIVE=OFF" # Hive metastore

    # ============================================
    # DISABLE CLOUD STORAGE
    # ============================================
    "-DENABLE_AWS_S3=OFF" # AWS S3
    "-DENABLE_AZURE_BLOB_STORAGE=OFF" # Azure Blob
    "-DENABLE_GOOGLE_CLOUD_CPP=OFF" # Google Cloud Storage
    "-DENABLE_HDFS=OFF" # Hadoop HDFS

    # ============================================
    # DISABLE UNUSED DATA FORMATS
    # (Protobuf enabled for GDP integration)
    # ============================================
    "-DENABLE_PARQUET=OFF" # Parquet (includes Arrow)
    "-DENABLE_ARROW_FLIGHT=OFF" # Arrow Flight
    "-DENABLE_AVRO=OFF" # Apache Avro
    "-DENABLE_CAPNP=OFF" # Cap'n Proto
    # "-DENABLE_PROTOBUF=OFF" # Protocol Buffers - ENABLED for GDP
    "-DENABLE_MSGPACK=OFF" # MessagePack

    # ============================================
    # DISABLE UNUSED INTERFACES
    # ============================================
    "-DENABLE_GRPC=OFF" # gRPC interface

    # ============================================
    # DISABLE ADVANCED FEATURES
    # ============================================
    "-DENABLE_EMBEDDED_COMPILER=OFF" # JIT compilation (LLVM) - saves ~200-300MB
    "-DENABLE_DWARF_PARSER=OFF" # DWARF debugging
    "-DENABLE_XRAY=OFF" # LLVM XRay instrumentation (requires LLVM)
    "-DENABLE_H3=OFF" # H3 geospatial
    "-DENABLE_S2_GEOMETRY=OFF" # S2 geometry
    "-DENABLE_NLP=OFF" # NLP functions
    "-DENABLE_VECTORSCAN=OFF" # Regex engine
    "-DENABLE_USEARCH=OFF" # Vector search
    "-DENABLE_DATASKETCHES=OFF" # Data sketches
    "-DENABLE_SIMSIMD=OFF" # SIMD similarity

    # ============================================
    # DISABLE AUTH FEATURES NOT NEEDED
    # ============================================
    "-DENABLE_LDAP=OFF" # LDAP authentication
    "-DENABLE_SSH=OFF" # SSH support
    "-DENABLE_JWT_CPP=OFF" # JWT tokens

    # ============================================
    # DISABLE DEVELOPMENT/OPTIONAL
    # ============================================
    "-DENABLE_PRQL=OFF" # PRQL language
    "-DENABLE_NURAFT=OFF" # Raft consensus (for Keeper)
    "-DENABLE_CLICKHOUSE_KEEPER=OFF" # Keeper functionality

    # ============================================
    # BUILD OPTIMIZATIONS
    # ============================================
    "-DBUILD_STANDALONE_KEEPER=OFF"
    "-DENABLE_EXAMPLES=OFF"
    "-DENABLE_BENCHMARKS=OFF"
  ];

  meta = (oldAttrs.meta or { }) // {
    description = "Minimal ClickHouse build for OTEL logging pipeline";
  };
})
