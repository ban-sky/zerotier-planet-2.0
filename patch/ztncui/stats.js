/*
  ztncui - runtime statistics reader.

  The privileged collector (stats-collector.js, started by the entrypoint as
  root) writes /app/config/runtime-stats.json; the UI only ever reads that file,
  so it never needs the ZeroTier authtoken itself. Values older than
  MAX_AGE_MS are reported as unavailable instead of being shown as "live".
*/

'use strict';

const fs = require('fs');

const STATS_FILE = process.env.RUNTIME_STATS_FILE || '/app/config/runtime-stats.json';
const MAX_AGE_MS = Math.max(5000, Number(process.env.RUNTIME_STATS_MAX_AGE_MS) || 30000);

function emptyStats() {
  return {
    available: false,
    ageSeconds: null,
    cpu: { percent: null, cores: null },
    mem: { used: null, total: null, percent: null },
    net: null
  };
}

function numberOrNull(value) {
  const n = Number(value);
  return Number.isFinite(n) && n >= 0 ? n : null;
}

function read() {
  let raw;
  try {
    raw = fs.readFileSync(STATS_FILE, 'utf8');
  } catch (err) {
    return emptyStats();
  }

  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    return emptyStats();
  }

  const collectedAt = numberOrNull(parsed.collected_at);
  const ageSeconds = collectedAt === null ? null : Math.max(0, Math.floor(Date.now() / 1000) - collectedAt);
  const fresh = ageSeconds !== null && ageSeconds * 1000 <= MAX_AGE_MS;

  const cpu = parsed.cpu || {};
  const mem = parsed.mem || {};
  const net = parsed.net || null;

  return {
    available: fresh,
    ageSeconds,
    cpu: {
      percent: fresh ? numberOrNull(cpu.percent) : null,
      cores: numberOrNull(cpu.cores),
      appPercent: fresh ? numberOrNull(cpu.appPercent) : null,
      limitCores: numberOrNull(cpu.limitCores)
    },
    mem: {
      used: numberOrNull(mem.used),
      total: numberOrNull(mem.total),
      percent: fresh ? numberOrNull(mem.percent) : null,
      appUsed: numberOrNull(mem.appUsed),
      appLimit: numberOrNull(mem.appLimit)
    },
    net: net && fresh
      ? {
          peers: numberOrNull(net.peers),
          direct: numberOrNull(net.direct),
          relay: numberOrNull(net.relay),
          paths: numberOrNull(net.paths)
        }
      : null
  };
}

function megabytes(bytes) {
  if (bytes === null || bytes === undefined) return null;
  // Whole megabytes: the hints print "used / total", decimals only add noise.
  return Math.round(bytes / (1024 * 1024));
}

// Values the templates and the refresh endpoint both use, so the first paint and
// the polled updates agree on formatting.
function summarise(stats) {
  const cpu = stats && stats.cpu ? stats.cpu : {};
  const mem = stats && stats.mem ? stats.mem : {};
  const net = stats && stats.net ? stats.net : null;
  return {
    available: Boolean(stats && stats.available),
    cpuPercent: cpu.percent === null || cpu.percent === undefined ? null : cpu.percent,
    cores: cpu.cores || null,
    cpuAppPercent: cpu.appPercent === null || cpu.appPercent === undefined ? null : cpu.appPercent,
    limitCores: cpu.limitCores || null,
    memUsedMb: megabytes(mem.used),
    memTotalMb: megabytes(mem.total),
    memPercent: mem.percent === null || mem.percent === undefined ? null : mem.percent,
    memAppMb: megabytes(mem.appUsed),
    memAppLimitMb: megabytes(mem.appLimit),
    peers: net ? net.peers : null,
    direct: net ? net.direct : null,
    relay: net ? net.relay : null,
    paths: net ? net.paths : null
  };
}

module.exports = { read, summarise, megabytes, STATS_FILE };
