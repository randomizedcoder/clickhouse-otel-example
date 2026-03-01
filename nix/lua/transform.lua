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
-- Input: 1708272000.123456789 (float seconds since epoch)
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
-- Tag format: kube.loggen.var.log.containers.<pod>_<namespace>_<container>-<id>.log
-- Or: kube.loggen.<pod>_<namespace>_<container>-<id>.log (if using Path_Key)
local function parse_k8s_tag(tag)
    if not tag then
        return "unknown", "unknown", "unknown"
    end

    -- Extract the filename part after containers.
    local filename = tag:match("containers%.(.+)$") or tag:match("kube%.loggen%.(.+)$")
    if filename then
        -- Parse: <pod>_<namespace>_<container>-<container_id>.log
        local pod, namespace, container_with_id = filename:match("([^_]+)_([^_]+)_(.+)")
        if pod and namespace then
            -- Remove container ID suffix (-<64 hex chars>.log)
            local container = container_with_id:match("(.+)%-[a-f0-9]+%.log$") or container_with_id
            return namespace, pod, container
        end
    end
    return "unknown", "unknown", "unknown"
end

-- Extract service name from K8s metadata labels or container name
-- Checks common label patterns: app, app.kubernetes.io/name, k8s-app
local function get_service_name(record, container)
    -- Try kubernetes labels first (from kubernetes filter)
    if record.kubernetes and record.kubernetes.labels then
        local labels = record.kubernetes.labels
        -- Common service name label patterns
        if labels["app"] then return labels["app"] end
        if labels["app.kubernetes.io/name"] then return labels["app.kubernetes.io/name"] end
        if labels["k8s-app"] then return labels["k8s-app"] end
    end
    -- Fall back to container name
    if container and container ~= "unknown" then
        return container
    end
    return "unknown"
end

-- Extract trace context from record (supports multiple naming conventions)
-- Handles: trace-id, traceId, trace_id (and similar for span)
local function extract_trace_context(record)
    local trace_id = record["trace-id"] or record["traceId"] or record["trace_id"] or ""
    local span_id = record["span-id"] or record["spanId"] or record["span_id"] or ""
    local trace_flags = record["trace-flags"] or record["traceFlags"] or record["trace_flags"] or 0
    return trace_id, span_id, tonumber(trace_flags) or 0
end

-- Detect severity from plain text log content
-- Looks for common log level prefixes like [ERROR], [WARN], etc.
local function detect_severity_from_text(text)
    if type(text) ~= "string" then return nil end
    local lower = text:lower()
    if lower:match("^%[?fatal%]?") or lower:match("^%[?panic%]?") then return "fatal" end
    if lower:match("^%[?error%]?") or lower:match("^%[?err%]?") then return "error" end
    if lower:match("^%[?warn") then return "warn" end
    if lower:match("^%[?debug%]?") then return "debug" end
    if lower:match("^%[?info%]?") then return "info" end
    return nil
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
        -- Also extract trace context from JSON
        local trace_id = log_str:match('"trace[_-]?[iI]d"%s*:%s*"([^"]+)"')
        local span_id = log_str:match('"span[_-]?[iI]d"%s*:%s*"([^"]+)"')

        if level and ts then
            return {
                level = level,
                ts = tonumber(ts),
                msg = msg,
                caller = caller,
                count = tonumber(count) or 0,
                random_number = tonumber(random_number) or 0,
                random_string = random_string or "",
                trace_id = trace_id or "",
                span_id = span_id or "",
            }
        end
    end
    return nil
end

-- Extract body and severity from record (handles both JSON and plain text)
local function extract_body_and_severity(record, log_data)
    local body = log_data.msg or ""
    local level = log_data.level

    -- If no structured message, use raw log as body
    if body == "" and record.log then
        body = tostring(record.log)
        -- Try to detect severity from plain text
        if not level then
            level = detect_severity_from_text(body)
        end
    end

    return body, level or "info"
end

-- Main transformation function called by FluentBit
-- tag: FluentBit tag (e.g., "kube.loggen.otel-demo_loggen-abc123_loggen")
-- timestamp: FluentBit timestamp (observation time)
-- record: The log record (table)
-- Returns: code, timestamp, new_record
--   code: 1 = keep record, 0 = drop record, -1 = error
function transform_to_otel(tag, timestamp, record)
    local namespace, pod, container = parse_k8s_tag(tag)

    -- Get node name from kubernetes filter metadata
    local node_name = ""
    if record.kubernetes and record.kubernetes.host then
        node_name = record.kubernetes.host
    end

    -- Check if we need to parse an inner JSON log
    local log_data = record
    if record.log and type(record.log) == "string" then
        local parsed = try_parse_json(record.log)
        if parsed then
            log_data = parsed
        end
    end

    -- Extract body and severity (handles plain text fallback)
    local body, level = extract_body_and_severity(record, log_data)

    -- Extract fields with defaults
    local ts = log_data.ts or timestamp
    local caller = log_data.caller or ""
    local count = log_data.count or 0
    local random_number = log_data.random_number or 0
    local random_string = log_data.random_string or ""

    -- Extract trace context from multiple sources
    local trace_id, span_id, trace_flags = extract_trace_context(record)
    if trace_id == "" and log_data.trace_id then trace_id = log_data.trace_id end
    if span_id == "" and log_data.span_id then span_id = log_data.span_id end

    -- Dynamic service name extraction
    local service_name = get_service_name(record, container)

    -- Build the OTel log record for ClickHouse
    local otel_record = {
        -- Timestamp as DateTime64(9) string (original log timestamp)
        Timestamp = format_timestamp(ts),

        -- ObservedTimestamp (when FluentBit observed the log)
        ObservedTimestamp = format_timestamp(timestamp),

        -- Trace context
        TraceId = trace_id,
        SpanId = span_id,
        TraceFlags = trace_flags,

        -- Severity
        SeverityText = severity_text[level] or "INFO",
        SeverityNumber = severity_number[level] or 9,

        -- Service identification (dynamic)
        ServiceName = service_name,

        -- Log body
        Body = body,

        -- Resource attributes as JSON string for Map type
        ResourceSchemaUrl = "",
        ResourceAttributes = map_to_json({
            ["service.name"] = service_name,
            ["service.version"] = "1.0.0",
            ["k8s.namespace.name"] = namespace,
            ["k8s.pod.name"] = pod,
            ["k8s.container.name"] = container,
            ["k8s.node.name"] = node_name,
        }),

        -- Scope attributes
        ScopeSchemaUrl = "",
        ScopeName = service_name,
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
