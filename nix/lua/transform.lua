-- transform.lua
-- Transforms FluentBit records to OTel log format for ClickHouse
-- This script is used by FluentBit's Lua filter to convert JSON logs
-- from the loggen application into the HyperDX-compatible OTel format.

-- Severity mapping from zap log levels to OTel severity numbers
-- See: https://opentelemetry.io/docs/specs/otel/logs/data-model/#severity-fields
local severity_number = {
    debug   = 5,   -- DEBUG
    info    = 9,   -- INFO
    warn    = 13,  -- WARN
    warning = 13,  -- WARN (alias)
    error   = 17,  -- ERROR
    dpanic  = 21,  -- FATAL
    panic   = 21,  -- FATAL
    fatal   = 21,  -- FATAL
}

local severity_text = {
    debug   = "DEBUG",
    info    = "INFO",
    warn    = "WARN",
    warning = "WARN",
    error   = "ERROR",
    dpanic  = "FATAL",
    panic   = "FATAL",
    fatal   = "FATAL",
}

-- Convert timestamp (float seconds from zap) to ClickHouse DateTime64(9) format
-- Input: 1708272000.123456789 (float seconds)
-- Output: "2024-02-18 12:00:00.123456789" (string for ClickHouse)
local function format_timestamp(ts)
    if type(ts) ~= "number" then
        return os.date("!%Y-%m-%d %H:%M:%S.000000000")
    end

    local seconds = math.floor(ts)
    local nanos = math.floor((ts - seconds) * 1e9)
    local date_str = os.date("!%Y-%m-%d %H:%M:%S", seconds)
    return string.format("%s.%09d", date_str, nanos)
end

-- Convert map to JSON-like string for ClickHouse Map type
local function map_to_json(tbl)
    if type(tbl) ~= "table" then
        return "{}"
    end

    local parts = {}
    for k, v in pairs(tbl) do
        local key = tostring(k)
        local val = tostring(v)
        -- Escape quotes in values
        val = val:gsub('"', '\\"')
        table.insert(parts, string.format('"%s":"%s"', key, val))
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Extract Kubernetes metadata from the FluentBit tag
-- Tag format: kube.loggen.<namespace>_<pod>_<container>
local function parse_k8s_tag(tag)
    if not tag then
        return "unknown", "unknown", "unknown"
    end

    local namespace, pod, container = string.match(tag, "kube%.loggen%.([^_]+)_([^_]+)_(.+)")
    return namespace or "unknown", pod or "unknown", container or "unknown"
end

-- Try to parse JSON string if the log field contains wrapped JSON
local function try_parse_json(log_str)
    -- Simple JSON extraction - look for {"level": pattern
    if type(log_str) == "string" and log_str:match('^%s*{') then
        -- This is a simplified JSON parser for our known format
        local level = log_str:match('"level"%s*:%s*"([^"]+)"')
        local ts = log_str:match('"ts"%s*:%s*([%d%.]+)')
        local msg = log_str:match('"msg"%s*:%s*"([^"]+)"')
        local caller = log_str:match('"caller"%s*:%s*"([^"]+)"')
        local count = log_str:match('"count"%s*:%s*(%d+)')
        local random_number = log_str:match('"random_number"%s*:%s*(%d+)')
        local random_string = log_str:match('"random_string"%s*:%s*"([^"]+)"')

        if level and ts then
            return {
                level = level,
                ts = tonumber(ts),
                msg = msg,
                caller = caller,
                count = tonumber(count) or 0,
                random_number = tonumber(random_number) or 0,
                random_string = random_string or "",
            }
        end
    end
    return nil
end

-- Main transformation function called by FluentBit
-- tag: FluentBit tag (e.g., "kube.loggen.otel-demo_loggen-abc123_loggen")
-- timestamp: FluentBit timestamp
-- record: The log record (table)
-- Returns: code, timestamp, new_record
--   code: 1 = keep record, 0 = drop record, -1 = error
function transform_to_otel(tag, timestamp, record)
    local namespace, pod, container = parse_k8s_tag(tag)

    -- Check if we need to parse an inner JSON log
    local log_data = record
    if record.log and type(record.log) == "string" then
        local parsed = try_parse_json(record.log)
        if parsed then
            log_data = parsed
        end
    end

    -- Extract fields with defaults
    local level = log_data.level or "info"
    local ts = log_data.ts or timestamp
    local msg = log_data.msg or ""
    local caller = log_data.caller or ""
    local count = log_data.count or 0
    local random_number = log_data.random_number or 0
    local random_string = log_data.random_string or ""

    -- Build the OTel log record for ClickHouse
    local otel_record = {
        -- Timestamp as DateTime64(9) string
        Timestamp = format_timestamp(ts),

        -- Trace context (empty for this demo)
        TraceId = "",
        SpanId = "",
        TraceFlags = 0,

        -- Severity
        SeverityText = severity_text[level] or "INFO",
        SeverityNumber = severity_number[level] or 9,

        -- Service identification
        ServiceName = "loggen",

        -- Log body
        Body = msg,

        -- Resource attributes as JSON string for Map type
        ResourceSchemaUrl = "",
        ResourceAttributes = map_to_json({
            ["service.name"] = "loggen",
            ["service.version"] = "1.0.0",
            ["k8s.namespace.name"] = namespace,
            ["k8s.pod.name"] = pod,
            ["k8s.container.name"] = container,
        }),

        -- Scope attributes
        ScopeSchemaUrl = "",
        ScopeName = "loggen",
        ScopeVersion = "1.0.0",
        ScopeAttributes = "{}",

        -- Log attributes
        LogAttributes = map_to_json({
            ["caller"] = caller,
        }),

        -- Custom indexed fields for demo queries
        RandomNumber = random_number,
        RandomString = random_string,
        Count = count,
    }

    return 1, timestamp, otel_record
end

-- Return the module for FluentBit
return transform_to_otel
