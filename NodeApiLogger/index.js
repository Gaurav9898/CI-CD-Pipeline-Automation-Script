const http = require("http");
const https = require("https");
const promClient = require("prom-client");

const parseBooleanEnv = (value, fallback) => {
  if (value == null || value === "") return fallback;
  return String(value).toLowerCase() === "true";
};

const parseIntegerEnv = (value, fallback) => {
  const parsed = parseInt(value, 10);
  return Number.isNaN(parsed) ? fallback : parsed;
};

const resolveProjectName = () => {
  const fromPackage = process.env.npm_package_name;
  if (fromPackage) return String(fromPackage).toLowerCase();
  return "nodeapilogger";
};

const LOG_LEVEL_WEIGHT = { error: 40, warn: 30, info: 20, debug: 10 };

const LOGGER_CONFIG_KEYS = new Set([
  "level",
  "service",
  "module",
  "env",
  "lokiEnabled",
  "lokiUrl",
  "lokiTimeoutMs",
  "lokiBatchSize",
  "lokiFlushIntervalMs",
  "lokiDropOnFailure",
  "printToConsole",
]);

const loggerDefaults = {
  level: process.env.LOG_LEVEL || "info",
  service: process.env.LOG_SERVICE || resolveProjectName(),
  module: process.env.LOG_MODULE || "index",
  env: process.env.LOG_ENV || process.env.NODE_ENV || "local",
  lokiEnabled: parseBooleanEnv(process.env.LOG_LOKI_ENABLED, true),
  lokiUrl:
    process.env.LOG_LOKI_URL ||
    "http://10.0.10.212:30031/loki/api/v1/push",
  lokiTimeoutMs: parseIntegerEnv(process.env.LOG_LOKI_TIMEOUT_MS, 5000),
  lokiBatchSize: parseIntegerEnv(process.env.LOG_LOKI_BATCH_SIZE, 20),
  lokiFlushIntervalMs: parseIntegerEnv(
    process.env.LOG_LOKI_FLUSH_INTERVAL_MS,
    2000
  ),
  lokiDropOnFailure: parseBooleanEnv(
    process.env.LOG_LOKI_DROP_ON_FAILURE,
    false
  ),
  printToConsole: false,
};

let loggerQueue = [];
let loggerFlushInProgress = false;
let loggerFlushTimer = null;
let loggerShutdownHookRegistered = false;

const normalizeLogLevel = (level) => {
  const value = String(level || "info").toLowerCase();
  return Object.prototype.hasOwnProperty.call(LOG_LEVEL_WEIGHT, value)
    ? value
    : "info";
};

const shouldWriteLog = (activeLevel, incomingLevel) => {
  return (
    LOG_LEVEL_WEIGHT[normalizeLogLevel(incomingLevel)] >=
    LOG_LEVEL_WEIGHT[normalizeLogLevel(activeLevel)]
  );
};

const splitHeadingAndDetail = (rawMessage) => {
  const lines = String(rawMessage == null ? "" : rawMessage)
    .split(/\r?\n/)
    .map((line) => line.trimEnd());

  const firstNonEmpty = lines.findIndex((line) => line.trim().length > 0);
  const heading = firstNonEmpty >= 0 ? lines[firstNonEmpty] : String(rawMessage);
  const detail =
    firstNonEmpty >= 0
      ? lines
          .slice(firstNonEmpty + 1)
          .map((line) => line.trim())
          .filter(Boolean)
          .join(" ")
      : "";

  return { heading, detail: detail || null };
};

const serializeErrorFields = (error, prefix) => {
  const safePrefix = prefix && prefix !== "error" ? `${prefix}_` : "";
  const fields = {};

  if (safePrefix) {
    fields[`${safePrefix}name`] = error.name || "Error";
    fields[`${safePrefix}error`] = error.message || String(error);
    if (error.stack) fields[`${safePrefix}stack`] = error.stack;
  } else {
    fields.error = error.message || String(error);
    if (error.stack) fields.stack = error.stack;
    if (error.name) fields.error_name = error.name;
  }

  return fields;
};

const normalizeFlatLogFields = (value, fallbackKey) => {
  if (value === null || value === undefined) return {};

  if (value instanceof Error) {
    return serializeErrorFields(value, fallbackKey);
  }

  if (typeof value === "object" && !Array.isArray(value)) {
    const normalized = {};

    Object.keys(value).forEach((key) => {
      const item = value[key];
      if (item === undefined) return;

      if (item instanceof Error) {
        Object.assign(
          normalized,
          serializeErrorFields(item, key === "error" ? "" : key)
        );
        return;
      }

      normalized[key] = item;
    });

    return normalized;
  }

  return { [fallbackKey || "data"]: value };
};

const writeConsole = (level, payload) => {
  const line = JSON.stringify(payload);
  if (level === "error") console.error(line);
  else if (level === "warn") console.warn(line);
  else if (level === "debug") console.debug(line);
  else console.log(line);
};

const buildLogPayload = (level, message, data, context) => {
  const now = new Date();
  const { heading, detail } = splitHeadingAndDetail(message);
  const payload = {
    timestamp: now.toISOString(),
    level,
    message: heading || String(message || ""),
    service: loggerDefaults.service,
    module: loggerDefaults.module,
    env: loggerDefaults.env,
  };

  Object.assign(payload, normalizeFlatLogFields(context, "context"));
  Object.assign(payload, normalizeFlatLogFields(data, "data"));

  if (detail && !payload.detail && !payload.message_detail) {
    payload.detail = detail;
    payload.message_detail = detail;
  }

  if (!payload.request_id && payload.requestId) {
    payload.request_id = payload.requestId;
  }

  if (
    payload.duration_seconds !== undefined &&
    payload.duration_ms === undefined &&
    !Number.isNaN(Number(payload.duration_seconds))
  ) {
    payload.duration_ms = Math.round(Number(payload.duration_seconds) * 1000);
  }

  return payload;
};

const buildLokiLabels = (payload) => {
  return {
    service: String(payload.service || loggerDefaults.service),
    module: String(payload.module || loggerDefaults.module),
    env: String(payload.env || loggerDefaults.env),
    level: String(payload.level || "info"),
    route: String(payload.route || "unknown"),
    servicename: String(payload.servicename || "unknown"),
  };
};

const pushLogBatchToLoki = async (batch) => {
  if (!loggerDefaults.lokiEnabled || !loggerDefaults.lokiUrl || batch.length === 0) {
    return { success: true, count: 0 };
  }

  const grouped = new Map();
  batch.forEach((item) => {
    const key = JSON.stringify(item.labels);
    if (!grouped.has(key)) {
      grouped.set(key, { stream: item.labels, values: [] });
    }
    grouped.get(key).values.push(item.value);
  });

  const requestBody = JSON.stringify({ streams: Array.from(grouped.values()) });
  const targetUrl = new URL(loggerDefaults.lokiUrl);
  const transport = targetUrl.protocol === "https:" ? https : http;

  return new Promise((resolve, reject) => {
    const request = transport.request(
      {
        hostname: targetUrl.hostname,
        port: targetUrl.port || (targetUrl.protocol === "https:" ? 443 : 80),
        path: `${targetUrl.pathname}${targetUrl.search}`,
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(requestBody),
        },
        timeout: loggerDefaults.lokiTimeoutMs,
      },
      (response) => {
        let responseBody = "";
        response.on("data", (chunk) => {
          responseBody += chunk.toString();
        });
        response.on("end", () => {
          if (response.statusCode >= 200 && response.statusCode < 300) {
            resolve({ success: true, count: batch.length });
            return;
          }

          reject(
            new Error(
              `Loki push failed with status ${response.statusCode}: ${responseBody}`
            )
          );
        });
      }
    );

    request.on("error", (error) => {
      reject(error);
    });

    request.on("timeout", () => {
      request.destroy(new Error("Loki request timeout"));
    });

    request.write(requestBody);
    request.end();
  });
};

const ensureLoggerTimer = () => {
  if (loggerFlushTimer) {
    clearInterval(loggerFlushTimer);
    loggerFlushTimer = null;
  }

  if (!loggerDefaults.lokiEnabled || loggerDefaults.lokiFlushIntervalMs <= 0) {
    return;
  }

  loggerFlushTimer = setInterval(() => {
    void exports.flushLoggerQueue();
  }, loggerDefaults.lokiFlushIntervalMs);

  if (typeof loggerFlushTimer.unref === "function") {
    loggerFlushTimer.unref();
  }
};

const registerLoggerShutdownHook = () => {
  if (loggerShutdownHookRegistered) return;

  loggerShutdownHookRegistered = true;
  process.once("beforeExit", () => {
    void exports.shutdownLogger();
  });
};

const enqueueLogPayload = (payload) => {
  if (!loggerDefaults.lokiEnabled || !loggerDefaults.lokiUrl) return;

  loggerQueue.push({
    labels: buildLokiLabels(payload),
    value: [
      String(new Date(payload.timestamp).getTime() * 1000000),
      JSON.stringify(payload),
    ],
  });

  if (loggerQueue.length >= loggerDefaults.lokiBatchSize) {
    void exports.flushLoggerQueue();
  }
};

const extractLoggerConfigOptions = (options) => {
  if (!options || typeof options !== "object") return {};

  const configOptions = {};
  Object.keys(options).forEach((key) => {
    if (LOGGER_CONFIG_KEYS.has(key)) {
      configOptions[key] = options[key];
    }
  });

  return configOptions;
};

const createScopedLogger = (baseContext) => {
  const normalizedBaseContext =
    baseContext && typeof baseContext === "object" ? { ...baseContext } : {};

  return {
    error: (message, data, extraContext) =>
      exports.logError(message, data, {
        ...normalizedBaseContext,
        ...(extraContext || {}),
      }),
    warn: (message, data, extraContext) =>
      exports.logWarn(message, data, {
        ...normalizedBaseContext,
        ...(extraContext || {}),
      }),
    info: (message, data, extraContext) =>
      exports.logInfo(message, data, {
        ...normalizedBaseContext,
        ...(extraContext || {}),
      }),
    debug: (message, data, extraContext) =>
      exports.logDebug(message, data, {
        ...normalizedBaseContext,
        ...(extraContext || {}),
      }),
    child: (childContext) =>
      createScopedLogger({
        ...normalizedBaseContext,
        ...(childContext || {}),
      }),
    flush: exports.flushLoggerQueue,
    shutdown: exports.shutdownLogger,
  };
};

exports.initLoggerDefaults = (options) => {
  if (options && typeof options === "object") {
    if (options.level) loggerDefaults.level = normalizeLogLevel(options.level);
    if (options.service) loggerDefaults.service = String(options.service);
    if (options.module) loggerDefaults.module = String(options.module);
    if (options.env) loggerDefaults.env = String(options.env);

    if (options.lokiEnabled !== undefined) {
      loggerDefaults.lokiEnabled =
        typeof options.lokiEnabled === "boolean"
          ? options.lokiEnabled
          : parseBooleanEnv(options.lokiEnabled, loggerDefaults.lokiEnabled);
    }

    if (options.lokiUrl) loggerDefaults.lokiUrl = String(options.lokiUrl);

    if (options.lokiTimeoutMs !== undefined) {
      loggerDefaults.lokiTimeoutMs = Math.max(
        1000,
        parseIntegerEnv(options.lokiTimeoutMs, loggerDefaults.lokiTimeoutMs)
      );
    }

    if (options.lokiBatchSize !== undefined) {
      loggerDefaults.lokiBatchSize = Math.max(
        1,
        parseIntegerEnv(options.lokiBatchSize, loggerDefaults.lokiBatchSize)
      );
    }

    if (options.lokiFlushIntervalMs !== undefined) {
      loggerDefaults.lokiFlushIntervalMs = Math.max(
        100,
        parseIntegerEnv(
          options.lokiFlushIntervalMs,
          loggerDefaults.lokiFlushIntervalMs
        )
      );
    }

    if (options.lokiDropOnFailure !== undefined) {
      loggerDefaults.lokiDropOnFailure =
        typeof options.lokiDropOnFailure === "boolean"
          ? options.lokiDropOnFailure
          : parseBooleanEnv(
              options.lokiDropOnFailure,
              loggerDefaults.lokiDropOnFailure
            );
    }

    if (options.printToConsole !== undefined) {
      loggerDefaults.printToConsole =
        typeof options.printToConsole === "boolean"
          ? options.printToConsole
          : parseBooleanEnv(options.printToConsole, loggerDefaults.printToConsole);
    }
  }

  ensureLoggerTimer();
  registerLoggerShutdownHook();
  return { ...loggerDefaults };
};

exports.getLoggerDefaults = () => {
  return { ...loggerDefaults };
};

exports.flushLoggerQueue = async () => {
  if (loggerFlushInProgress) {
    return {
      success: false,
      count: 0,
      skipped: true,
      pending: loggerQueue.length,
    };
  }

  if (!loggerDefaults.lokiEnabled || !loggerDefaults.lokiUrl) {
    loggerQueue.length = 0;
    return { success: true, count: 0 };
  }

  if (loggerQueue.length === 0) return { success: true, count: 0 };

  loggerFlushInProgress = true;
  const batch = loggerQueue.splice(0, loggerDefaults.lokiBatchSize);

  try {
    const result = await pushLogBatchToLoki(batch);
    return result;
  } catch (error) {
    if (!loggerDefaults.lokiDropOnFailure) {
      loggerQueue.unshift(...batch);
    }

    return {
      success: false,
      count: batch.length,
      error: error.message,
    };
  } finally {
    loggerFlushInProgress = false;
  }
};

exports.shutdownLogger = async () => {
  if (loggerFlushTimer) {
    clearInterval(loggerFlushTimer);
    loggerFlushTimer = null;
  }

  let totalFlushed = 0;
  while (loggerQueue.length > 0) {
    const result = await exports.flushLoggerQueue();
    if (!result.success && result.error) {
      return {
        success: false,
        flushed: totalFlushed,
        pending: loggerQueue.length,
        error: result.error,
      };
    }
    totalFlushed += result.count;
    if (result.skipped) break;
  }

  return { success: true, flushed: totalFlushed };
};

exports.logWithContext = (level, message, data, context) => {
  const normalizedLevel = normalizeLogLevel(level);
  if (!shouldWriteLog(loggerDefaults.level, normalizedLevel)) return null;

  const payload = buildLogPayload(normalizedLevel, message, data, context);

  if (loggerDefaults.printToConsole) {
    writeConsole(normalizedLevel, payload);
  }

  enqueueLogPayload(payload);
  return payload;
};

exports.logError = (message, data, context) => {
  return exports.logWithContext("error", message, data, context);
};

exports.logWarn = (message, data, context) => {
  return exports.logWithContext("warn", message, data, context);
};

exports.logInfo = (message, data, context) => {
  return exports.logWithContext("info", message, data, context);
};

exports.logDebug = (message, data, context) => {
  return exports.logWithContext("debug", message, data, context);
};

exports.createRequestLogger = (baseContext) => {
  return createScopedLogger(baseContext);
};

exports.createContextLogger = (options = {}) => {
  const configOptions = extractLoggerConfigOptions(options);
  if (Object.keys(configOptions).length > 0) {
    exports.initLoggerDefaults(configOptions);
  }

  return {
    error: (message, data, context) => exports.logError(message, data, context),
    warn: (message, data, context) => exports.logWarn(message, data, context),
    info: (message, data, context) => exports.logInfo(message, data, context),
    debug: (message, data, context) => exports.logDebug(message, data, context),
    child: (baseContext) => createScopedLogger(baseContext),
    flush: exports.flushLoggerQueue,
    shutdown: exports.shutdownLogger,
  };
};

const metricsDefaults = {
  service: process.env.METRICS_SERVICE || loggerDefaults.service,
  env: process.env.METRICS_ENV || loggerDefaults.env,
  collectDefaultMetrics: parseBooleanEnv(
    process.env.METRICS_COLLECT_DEFAULT,
    true
  ),
};

const metricsRegistry = new promClient.Registry();
let defaultMetricsStarted = false;
let defaultMetricsInterval = null;

const metricsSnapshotStore = {
  counters: {},
  observations: {},
};

const applyMetricsDefaultLabels = () => {
  metricsRegistry.setDefaultLabels({
    service: String(metricsDefaults.service),
    env: String(metricsDefaults.env),
  });
};

const ensureDefaultMetrics = () => {
  if (metricsDefaults.collectDefaultMetrics && !defaultMetricsStarted) {
    defaultMetricsInterval = promClient.collectDefaultMetrics({
      register: metricsRegistry,
    });
    if (
      defaultMetricsInterval &&
      typeof defaultMetricsInterval.unref === "function"
    ) {
      defaultMetricsInterval.unref();
    }
    defaultMetricsStarted = true;
  }
};

const normalizeMetricName = (metricName) => {
  const cleanName = String(metricName || "")
    .trim()
    .replace(/\s+/g, "_")
    .replace(/[^a-zA-Z0-9_:]/g, "_")
    .toLowerCase();
  return cleanName || "unnamed_metric";
};

const normalizeMetricRoute = (route) => {
  if (!route) return "unknown";

  return String(route)
    .split("?")[0]
    .replace(/\/[0-9]+(?=\/|$)/g, "/:id")
    .replace(
      /\/[0-9a-f]{8}-[0-9a-f-]{27,36}(?=\/|$)/gi,
      "/:id"
    );
};

const normalizeMetricLabelValue = (labelName, value) => {
  if (labelName === "route") return normalizeMetricRoute(value);
  if (labelName === "method") {
    return value ? String(value).toUpperCase() : "UNKNOWN";
  }
  if (labelName === "code") {
    return value == null || value === "" ? "0" : String(value);
  }
  return value == null || value === "" ? "unknown" : String(value);
};

const normalizeLabels = (labels) => {
  if (!labels || typeof labels !== "object" || Array.isArray(labels)) return {};

  const keys = Object.keys(labels).sort();
  const normalized = {};
  keys.forEach((key) => {
    normalized[String(key)] = String(labels[key]);
  });
  return normalized;
};

const getSeriesKey = (metricName, labels) => {
  return `${normalizeMetricName(metricName)}|${JSON.stringify(normalizeLabels(labels))}`;
};

const updateCounterSnapshot = (metricName, labels, value) => {
  const seriesKey = getSeriesKey(metricName, labels);
  if (!metricsSnapshotStore.counters[seriesKey]) {
    metricsSnapshotStore.counters[seriesKey] = {
      metric: normalizeMetricName(metricName),
      labels: normalizeLabels(labels),
      value: 0,
    };
  }

  metricsSnapshotStore.counters[seriesKey].value += value;
  return { ...metricsSnapshotStore.counters[seriesKey] };
};

const updateObservationSnapshot = (metricName, labels, value) => {
  const seriesKey = getSeriesKey(metricName, labels);
  if (!metricsSnapshotStore.observations[seriesKey]) {
    metricsSnapshotStore.observations[seriesKey] = {
      metric: normalizeMetricName(metricName),
      labels: normalizeLabels(labels),
      values: [],
      sum: 0,
      count: 0,
      min: null,
      max: null,
      avg: 0,
      last: null,
    };
  }

  const series = metricsSnapshotStore.observations[seriesKey];
  series.values.push(value);
  series.sum += value;
  series.count += 1;
  series.last = value;
  series.min = series.min === null ? value : Math.min(series.min, value);
  series.max = series.max === null ? value : Math.max(series.max, value);
  series.avg = series.count > 0 ? series.sum / series.count : 0;

  return {
    metric: series.metric,
    labels: { ...series.labels },
    sum: series.sum,
    count: series.count,
    min: series.min,
    max: series.max,
    avg: series.avg,
    last: series.last,
  };
};

applyMetricsDefaultLabels();
ensureDefaultMetrics();

const httpRequestDurationSeconds = new promClient.Histogram({
  name: "http_request_duration_seconds",
  help: "Duration of HTTP requests in seconds",
  labelNames: ["method", "route", "code"],
  buckets: [0.05, 0.1, 0.3, 0.5, 0.7, 1, 3, 5, 7, 10],
  registers: [metricsRegistry],
});

const graphqlOperationsTotal = new promClient.Counter({
  name: "graphql_operations_total",
  help: "Total GraphQL operations executed",
  labelNames: ["operation", "route", "status"],
  registers: [metricsRegistry],
});

const graphqlOperationDurationSeconds = new promClient.Histogram({
  name: "graphql_operation_duration_seconds",
  help: "Duration of GraphQL operations in seconds",
  labelNames: ["operation", "route", "status"],
  buckets: [0.05, 0.1, 0.3, 0.5, 1, 2, 5],
  registers: [metricsRegistry],
});

const authFailuresTotal = new promClient.Counter({
  name: "auth_failures_total",
  help: "Total authentication failures at the application layer",
  labelNames: ["reason"],
  registers: [metricsRegistry],
});

const loginBlocksTotal = new promClient.Counter({
  name: "login_blocks_total",
  help: "Total IP login blocks enforced",
  labelNames: ["type"],
  registers: [metricsRegistry],
});

const loginCaptchaRequiredTotal = new promClient.Counter({
  name: "login_captcha_required_total",
  help: "Total times a login attempt triggered a CAPTCHA requirement",
  registers: [metricsRegistry],
});

const loginFailedAttemptsTotal = new promClient.Counter({
  name: "login_failed_attempts_total",
  help: "Total failed login attempts tracked by the rate limiter",
  labelNames: ["stage"],
  registers: [metricsRegistry],
});

const metricCatalog = {
  http_request_duration_seconds: {
    name: "http_request_duration_seconds",
    type: "histogram",
    labelNames: ["method", "route", "code"],
    metric: httpRequestDurationSeconds,
  },
  graphql_operations_total: {
    name: "graphql_operations_total",
    type: "counter",
    labelNames: ["operation", "route", "status"],
    metric: graphqlOperationsTotal,
  },
  graphql_operation_duration_seconds: {
    name: "graphql_operation_duration_seconds",
    type: "histogram",
    labelNames: ["operation", "route", "status"],
    metric: graphqlOperationDurationSeconds,
  },
  auth_failures_total: {
    name: "auth_failures_total",
    type: "counter",
    labelNames: ["reason"],
    metric: authFailuresTotal,
  },
  login_blocks_total: {
    name: "login_blocks_total",
    type: "counter",
    labelNames: ["type"],
    metric: loginBlocksTotal,
  },
  login_captcha_required_total: {
    name: "login_captcha_required_total",
    type: "counter",
    labelNames: [],
    metric: loginCaptchaRequiredTotal,
  },
  login_failed_attempts_total: {
    name: "login_failed_attempts_total",
    type: "counter",
    labelNames: ["stage"],
    metric: loginFailedAttemptsTotal,
  },
};

const getMetricDefinition = (metricName) => {
  return metricCatalog[normalizeMetricName(metricName)] || null;
};

const normalizeLabelsForDefinition = (definition, labels) => {
  const source = labels && typeof labels === "object" ? labels : {};
  const normalized = {};

  definition.labelNames.forEach((labelName) => {
    normalized[labelName] = normalizeMetricLabelValue(labelName, source[labelName]);
  });

  return normalized;
};

const removeMetricSnapshots = (metricName) => {
  const normalizedMetricName = normalizeMetricName(metricName);

  Object.keys(metricsSnapshotStore.counters).forEach((seriesKey) => {
    if (metricsSnapshotStore.counters[seriesKey].metric === normalizedMetricName) {
      delete metricsSnapshotStore.counters[seriesKey];
    }
  });

  Object.keys(metricsSnapshotStore.observations).forEach((seriesKey) => {
    if (
      metricsSnapshotStore.observations[seriesKey].metric === normalizedMetricName
    ) {
      delete metricsSnapshotStore.observations[seriesKey];
    }
  });
};

exports.initMetricsDefaults = (options) => {
  if (options && typeof options === "object") {
    if (options.service) metricsDefaults.service = String(options.service);
    if (options.env) metricsDefaults.env = String(options.env);
    if (options.collectDefaultMetrics !== undefined) {
      metricsDefaults.collectDefaultMetrics =
        typeof options.collectDefaultMetrics === "boolean"
          ? options.collectDefaultMetrics
          : parseBooleanEnv(
              options.collectDefaultMetrics,
              metricsDefaults.collectDefaultMetrics
            );
    }
  }

  applyMetricsDefaultLabels();
  ensureDefaultMetrics();

  return { ...metricsDefaults };
};

exports.getMetricsRegistry = () => {
  return metricsRegistry;
};

exports.register = metricsRegistry;
exports.httpRequestDurationMicroseconds = httpRequestDurationSeconds;
exports.gqlOperationCounter = graphqlOperationsTotal;
exports.gqlOperationDuration = graphqlOperationDurationSeconds;
exports.authFailureCounter = authFailuresTotal;
exports.loginBlockCounter = loginBlocksTotal;
exports.loginCaptchaCounter = loginCaptchaRequiredTotal;
exports.loginFailedAttemptCounter = loginFailedAttemptsTotal;

exports.getMetricHandle = (metricName) => {
  const definition = getMetricDefinition(metricName);
  return definition ? definition.metric : null;
};

exports.getMetricsContentType = () => {
  return metricsRegistry.contentType;
};

exports.getMetricsText = async () => {
  return metricsRegistry.metrics();
};

exports.getMetricsHandler = () => {
  return async (_req, res) => {
    const metricsText = await metricsRegistry.metrics();

    if (typeof res.set === "function") {
      res.set("Content-Type", metricsRegistry.contentType);
    } else if (typeof res.setHeader === "function") {
      res.setHeader("Content-Type", metricsRegistry.contentType);
    }

    if (typeof res.status === "function" && typeof res.send === "function") {
      return res.status(200).send(metricsText);
    }

    if (typeof res.writeHead === "function") {
      res.writeHead(200, { "Content-Type": metricsRegistry.contentType });
    }

    if (typeof res.end === "function") {
      return res.end(metricsText);
    }

    return metricsText;
  };
};

exports.metricsMiddleware = (route = "/metrics") => {
  const handler = exports.getMetricsHandler();

  return async (req, res, next) => {
    const requestMethod = String(req.method || "GET").toUpperCase();
    const requestPath =
      req.path ||
      (typeof req.url === "string" ? req.url.split("?")[0] : "") ||
      "";

    if (requestMethod !== "GET" || requestPath !== route) {
      if (typeof next === "function") return next();
      return undefined;
    }

    return handler(req, res, next);
  };
};

exports.incMetric = (metricName, labels, value) => {
  const definition = getMetricDefinition(metricName);
  if (!definition || definition.type !== "counter") return null;

  const safeValue = Number.isFinite(+value) ? +value : 1;
  const normalizedLabels = normalizeLabelsForDefinition(definition, labels);

  if (definition.labelNames.length > 0) {
    definition.metric.inc(normalizedLabels, safeValue);
  } else {
    definition.metric.inc(safeValue);
  }

  return updateCounterSnapshot(definition.name, normalizedLabels, safeValue);
};

exports.observeMetric = (metricName, labels, value) => {
  const definition = getMetricDefinition(metricName);
  if (!definition || definition.type !== "histogram") return null;

  const safeValue = Number.isFinite(+value) ? +value : 0;
  const normalizedLabels = normalizeLabelsForDefinition(definition, labels);

  if (definition.labelNames.length > 0) {
    definition.metric.observe(normalizedLabels, safeValue);
  } else {
    definition.metric.observe(safeValue);
  }

  return updateObservationSnapshot(definition.name, normalizedLabels, safeValue);
};

exports.getMetric = (metricName) => {
  const normalizedMetricName = normalizeMetricName(metricName);
  const definition = getMetricDefinition(normalizedMetricName);

  const counters = Object.values(metricsSnapshotStore.counters)
    .filter((item) => item.metric === normalizedMetricName)
    .map((item) => ({ ...item, labels: { ...item.labels } }));

  const observations = Object.values(metricsSnapshotStore.observations)
    .filter((item) => item.metric === normalizedMetricName)
    .map((item) => ({
      metric: item.metric,
      labels: { ...item.labels },
      sum: item.sum,
      count: item.count,
      min: item.min,
      max: item.max,
      avg: item.avg,
      last: item.last,
    }));

  return {
    metric: normalizedMetricName,
    type: definition ? definition.type : null,
    labelNames: definition ? [...definition.labelNames] : [],
    counters,
    observations,
  };
};

exports.getAllMetrics = () => {
  const counters = Object.values(metricsSnapshotStore.counters).map((item) => ({
    metric: item.metric,
    labels: { ...item.labels },
    value: item.value,
  }));

  const observations = Object.values(metricsSnapshotStore.observations).map(
    (item) => ({
      metric: item.metric,
      labels: { ...item.labels },
      sum: item.sum,
      count: item.count,
      min: item.min,
      max: item.max,
      avg: item.avg,
      last: item.last,
    })
  );

  return {
    metrics: Object.keys(metricCatalog),
    counters,
    observations,
  };
};

exports.resetMetrics = (metricName) => {
  if (!metricName) {
    Object.keys(metricCatalog).forEach((key) => {
      metricCatalog[key].metric.reset();
    });
    metricsSnapshotStore.counters = {};
    metricsSnapshotStore.observations = {};
    return true;
  }

  const definition = getMetricDefinition(metricName);
  if (!definition) return false;

  definition.metric.reset();
  removeMetricSnapshots(definition.name);
  return true;
};

exports.startMetricTimer = (metricName, labels) => {
  const startTime = Date.now();
  return (extraLabels) => {
    const durationSeconds = (Date.now() - startTime) / 1000;
    const finalLabels =
      extraLabels && typeof extraLabels === "object"
        ? { ...(labels || {}), ...extraLabels }
        : labels;
    return exports.observeMetric(metricName, finalLabels, durationSeconds);
  };
};

exports.observeHttpRequest = (method, route, code, durationSeconds) => {
  return exports.observeMetric(
    "http_request_duration_seconds",
    { method, route, code },
    durationSeconds
  );
};

exports.startHttpMetricTimer = (method, route) => {
  const startTime = Date.now();
  return (code) => {
    const durationSeconds = (Date.now() - startTime) / 1000;
    return exports.observeHttpRequest(method, route, code, durationSeconds);
  };
};

exports.observeGraphqlOperation = (operation, status, durationSeconds, route) => {
  const labels = {
    operation,
    route: route || "/graphql",
    status: status || "success",
  };

  exports.incMetric("graphql_operations_total", labels, 1);
  return exports.observeMetric("graphql_operation_duration_seconds", labels, durationSeconds);
};

exports.incrementAuthFailure = (reason) => {
  return exports.incMetric("auth_failures_total", { reason }, 1);
};

exports.incrementLoginBlock = (type) => {
  return exports.incMetric("login_blocks_total", { type }, 1);
};

exports.incrementLoginCaptcha = () => {
  return exports.incMetric("login_captcha_required_total", {}, 1);
};

exports.incrementLoginFailedAttempt = (stage) => {
  return exports.incMetric("login_failed_attempts_total", { stage }, 1);
};

exports.metrics = {
  register: metricsRegistry,
  httpRequestDurationMicroseconds: httpRequestDurationSeconds,
  gqlOperationCounter: graphqlOperationsTotal,
  gqlOperationDuration: graphqlOperationDurationSeconds,
  authFailureCounter: authFailuresTotal,
  loginBlockCounter: loginBlocksTotal,
  loginCaptchaCounter: loginCaptchaRequiredTotal,
  loginFailedAttemptCounter: loginFailedAttemptsTotal,
};

exports.initLoggerDefaults({});

const getRequestIdFromContext = (ctx) => {
  if (!ctx || typeof ctx !== "object") return undefined;
  return (
    ctx.request_id ||
    ctx.requestId ||
    ctx.reqId ||
    (ctx.req && (ctx.req.id || ctx.req.request_id || ctx.req.requestId))
  );
};

const buildGraphqlLogContext = (operationName, operationContext, metricLabels) => {
  const logContext =
    metricLabels && typeof metricLabels === "object"
      ? normalizeFlatLogFields(metricLabels, "context")
      : {};

  const requestId = getRequestIdFromContext(operationContext);
  if (requestId) logContext.request_id = requestId;
  if (!logContext.route) logContext.route = "/graphql";
  if (!logContext.queryName) {
    logContext.queryName = String(operationName || "unknown_operation");
  }

  return logContext;
};

exports.runGraphqlOperationWithObservability = async (
  operationName,
  operationFn,
  operationContext,
  metricLabels
) => {
  const safeOperationName = String(operationName || "unknown_operation");
  const startTime = Date.now();
  const logContext = buildGraphqlLogContext(
    safeOperationName,
    operationContext,
    metricLabels
  );

  exports.logInfo(
    "graphql operation started",
    {
      operation: safeOperationName,
      status: "started",
    },
    logContext
  );

  try {
    const result = await operationFn();
    const durationSeconds = (Date.now() - startTime) / 1000;
    const durationMs = Math.round(durationSeconds * 1000);

    exports.observeGraphqlOperation(
      logContext.queryName || safeOperationName,
      "success",
      durationSeconds,
      logContext.route
    );

    exports.logInfo(
      "graphql operation completed",
      {
        operation: safeOperationName,
        status: "success",
        duration_ms: durationMs,
      },
      logContext
    );

    return result;
  } catch (error) {
    const durationSeconds = (Date.now() - startTime) / 1000;
    const durationMs = Math.round(durationSeconds * 1000);

    exports.observeGraphqlOperation(
      logContext.queryName || safeOperationName,
      "error",
      durationSeconds,
      logContext.route
    );

    exports.logError(
      "graphql operation failed",
      {
        operation: safeOperationName,
        status: "error",
        duration_ms: durationMs,
        error,
      },
      logContext
    );

    throw error;
  }
};

exports.wrapGraphqlResolverWithObservability = (
  operationName,
  resolverFn,
  labelsBuilder
) => {
  return async (...resolverArgs) => {
    const resolverContext = resolverArgs.length >= 3 ? resolverArgs[2] : null;
    const dynamicLabels =
      typeof labelsBuilder === "function"
        ? labelsBuilder(...resolverArgs)
        : undefined;

    return exports.runGraphqlOperationWithObservability(
      operationName,
      async () => resolverFn(...resolverArgs),
      resolverContext,
      dynamicLabels
    );
  };
};

exports.wrapGraphqlResolverWithCommonLabels = (
  operationName,
  resolverFn,
  options
) => {
  const defaults = {
    route: "/graphql",
    includeRequestId: true,
    extraLabels: {},
  };

  const normalizedOptions =
    options && typeof options === "object" ? { ...defaults, ...options } : defaults;

  const labelsBuilder = (_parent, _args, context) => {
    const requestId = getRequestIdFromContext(context);
    const labels = {
      queryName: String(operationName || "unknown_operation"),
      route: normalizedOptions.route,
      ...(normalizedOptions.extraLabels &&
      typeof normalizedOptions.extraLabels === "object"
        ? normalizedOptions.extraLabels
        : {}),
    };

    if (normalizedOptions.includeRequestId && requestId) {
      labels.request_id = String(requestId);
    }

    return labels;
  };

  return exports.wrapGraphqlResolverWithObservability(
    operationName,
    resolverFn,
    labelsBuilder
  );
};
