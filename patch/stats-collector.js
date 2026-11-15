/*
  zerotier-planet 2.0 - runtime statistics collector.

  Runs as root next to zerotier-one (it needs the controller's authtoken to ask
  for the peer list), samples the *host* CPU and memory counters plus the
  container's own share of them, and writes a small JSON file the controller UI
  can read without any privileges of its own:

      {"collected_at":1700000000,"interval_ms":5000,
       "cpu":{"percent":12.5,"cores":8,"appPercent":3.1,"limitCores":2},
       "mem":{"used":6442450944,"total":17179869184,"percent":37.5,
              "appUsed":73400320,"appLimit":536870912},
       "net":{"peers":4,"direct":3,"relay":1,"paths":5}}

  `cpu.percent` / `mem.*` describe the whole machine (the numbers a user sees in
  `top`), because "how busy is this server" is the question the overview answers;
  `cpu.appPercent` / `mem.appUsed` describe only this container. Everything is
  best effort: a missing /proc or cgroup only drops that field, it never stops
  the loop.
*/

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

const INTERVAL_MS = Math.max(2000, Number(process.env.STATS_INTERVAL_MS) || 5000);
const STATS_FILE = process.env.STATS_FILE || '/app/config/runtime-stats.json';
const ZT_HOME = process.env.ZT_HOME || '/var/lib/zerotier-one';
const ZT_PORT = String(process.env.ZT_PORT || '9994');
const ZT_CLI = process.env.ZT_CLI || '/usr/sbin/zerotier-cli';

function readText(file) {
  try {
    return fs.readFileSync(file, 'utf8');
  } catch (err) {
    return '';
  }
}

function readFirstLine(file) {
  return readText(file).split('\n')[0];
}

function numberOrNull(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

function round1(n) {
  return Math.round(n * 10) / 10;
}

// --- CPU -------------------------------------------------------------------
// /proc/stat is not namespaced, so it always reports the whole machine - that is
// what we show first. The cgroup counters tell us how much of it this container
// used, and are reported next to it.

function readCgroupUsageUsec() {
  const v2 = readText('/sys/fs/cgroup/cpu.stat');
  if (v2) {
    const m = /^usage_usec\s+(\d+)/m.exec(v2);
    if (m) return Number(m[1]);
  }
  const v1 = (readFirstLine('/sys/fs/cgroup/cpuacct/cpuacct.usage') || '').trim();
  if (/^\d+$/.test(v1)) return Math.round(Number(v1) / 1000);
  return null;
}

function readCgroupLimitCores() {
  // cgroup v2: "max 100000" means unlimited, otherwise "<quota> <period>".
  const v2 = (readFirstLine('/sys/fs/cgroup/cpu.max') || '').trim();
  if (v2) {
    const [quota, period] = v2.split(/\s+/);
    if (quota === 'max' || !period) return null;
    const cores = Number(quota) / Number(period);
    return Number.isFinite(cores) && cores > 0 ? round1(cores) : null;
  }
  // cgroup v1: quota/period under cpu/cpu.cfs_*.
  const quota = numberOrNull((readFirstLine('/sys/fs/cgroup/cpu/cpu.cfs_quota_us') || '').trim());
  const period = numberOrNull((readFirstLine('/sys/fs/cgroup/cpu/cpu.cfs_period_us') || '').trim());
  if (quota && period && quota > 0) return round1(quota / period);
  return null;
}

function readProcStat() {
  const line = readFirstLine('/proc/stat');
  if (!line || line.indexOf('cpu ') !== 0) return null;
  const parts = line.trim().split(/\s+/).slice(1).map(Number);
  if (parts.length < 4 || parts.some((n) => !Number.isFinite(n))) return null;
  const idle = parts[3] + (parts[4] || 0);
  const total = parts.reduce((a, b) => a + b, 0);
  return { idle, total };
}

function hostCpuPercent(prev, now) {
  if (!prev || !prev.proc || !now || !now.proc) return null;
  const dTotal = now.proc.total - prev.proc.total;
  const dIdle = now.proc.idle - prev.proc.idle;
  if (dTotal <= 0) return null;
  return round1(((dTotal - dIdle) / dTotal) * 100);
}

function appCpuPercent(prev, now) {
  // Share of a single core, the way `docker stats` reports it.
  if (!prev || prev.usageUsec === null || now.usageUsec === null) return null;
  const elapsed = now.at - prev.at;
  if (elapsed <= 0) return null;
  return round1(((now.usageUsec - prev.usageUsec) / 1000 / elapsed) * 100);
}

// --- memory ----------------------------------------------------------------

function readHostMemory() {
  const info = readText('/proc/meminfo');
  const mTotal = /^MemTotal:\s+(\d+) kB/m.exec(info);
  if (!mTotal) return null;
  const total = Number(mTotal[1]) * 1024;
  const mAvail = /^MemAvailable:\s+(\d+) kB/m.exec(info);
  let available = mAvail ? Number(mAvail[1]) * 1024 : null;
  if (available === null) {
    const free = /^MemFree:\s+(\d+) kB/m.exec(info);
    const buffers = /^Buffers:\s+(\d+) kB/m.exec(info);
    const cached = /^Cached:\s+(\d+) kB/m.exec(info);
    if (free) {
      available = Number(free[1]) * 1024 +
        (buffers ? Number(buffers[1]) * 1024 : 0) +
        (cached ? Number(cached[1]) * 1024 : 0);
    }
  }
  if (available === null) return null;
  const used = Math.max(0, total - available);
  return {
    used,
    total,
    percent: total > 0 ? round1((used / total) * 100) : null
  };
}

function readCgroupMemory() {
  let used = numberOrNull((readFirstLine('/sys/fs/cgroup/memory.current') || '').trim());
  let limit = numberOrNull((readFirstLine('/sys/fs/cgroup/memory.max') || '').trim());
  if (used === null) {
    used = numberOrNull((readFirstLine('/sys/fs/cgroup/memory/memory.usage_in_bytes') || '').trim());
    limit = numberOrNull((readFirstLine('/sys/fs/cgroup/memory/memory.limit_in_bytes') || '').trim());
  }
  // "max" (v2) or a huge sentinel (v1) means "no limit".
  if (limit !== null && limit > os.totalmem()) limit = null;
  return { used, limit };
}

// --- ZeroTier --------------------------------------------------------------

function execFileAsync(file, args) {
  return new Promise((resolve) => {
    execFile(file, args, { timeout: 5000, maxBuffer: 1 << 20 }, (err, stdout) => {
      resolve(err ? '' : String(stdout || ''));
    });
  });
}

async function readNetwork() {
  const raw = await execFileAsync(ZT_CLI, ['-p' + ZT_PORT, '-D' + ZT_HOME, '-j', 'peers']);

  if (!raw.trim()) return null;
  let peers;
  try {
    peers = JSON.parse(raw);
  } catch (err) {
    return null;
  }
  if (!Array.isArray(peers)) return null;

  let online = 0;
  let direct = 0;
  let relay = 0;
  let paths = 0;
  for (const peer of peers) {
    if (peer.role && peer.role !== 'LEAF') continue;
    const active = (peer.paths || []).filter((p) => p.active && !p.expired);
    paths += active.length;
    if (!active.length) continue;
    online += 1;
    if (Number(peer.latency) >= 0) direct += 1;
    else relay += 1;
  }
  return { peers: online, direct, relay, paths };
}

// --- loop ------------------------------------------------------------------

let previous = null;

async function sample() {
  const started = Date.now();
  const usageUsec = readCgroupUsageUsec();
  const now = { at: started, usageUsec, proc: readProcStat() };

  const host = readHostMemory();
  const app = readCgroupMemory();
  const cores = os.cpus().length || 1;

  // Fall back to the container's own numbers when /proc is not readable.
  const mem = host || (app.used !== null
    ? {
      used: app.used,
      total: app.limit || os.totalmem(),
      percent: (app.limit || os.totalmem()) > 0
        ? round1((app.used / (app.limit || os.totalmem())) * 100)
        : null
    }
    : null);

  const snapshot = {
    collected_at: Math.floor(started / 1000),
    interval_ms: INTERVAL_MS,
    cpu: {
      percent: hostCpuPercent(previous, now),
      cores,
      appPercent: appCpuPercent(previous, now),
      limitCores: readCgroupLimitCores()
    },
    mem: mem
      ? Object.assign({}, mem, {
        appUsed: app.used,
        appLimit: app.limit
      })
      : null,
    net: null
  };

  previous = now;

  snapshot.net = await readNetwork();

  const tmp = STATS_FILE + '.tmp';
  try {
    fs.writeFileSync(tmp, JSON.stringify(snapshot) + '\n', { mode: 0o644 });
    fs.renameSync(tmp, STATS_FILE);
    fs.chmodSync(STATS_FILE, 0o644);
  } catch (err) {
    // The config volume may be read-only while it is being set up; retry later.
  }

  const elapsed = Date.now() - started;
  setTimeout(sample, Math.max(1000, INTERVAL_MS - elapsed));
}

process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT', () => process.exit(0));

fs.mkdirSync(path.dirname(STATS_FILE), { recursive: true });
sample();
