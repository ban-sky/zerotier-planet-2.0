/*
  zerotier-planet 2.0 - runtime statistics collector.

  Runs as root next to zerotier-one (it needs the controller's authtoken to ask
  for the peer list), samples CPU/memory from the cgroup and the ZeroTier peer
  table, and writes a small JSON file that the controller UI can read without
  any privileges of its own:

      {"collected_at":1700000000,"interval_ms":15000,
       "cpu":{"percent":3.1,"cores":2},
       "mem":{"used":73400320,"total":536870912,"percent":13.7},
       "net":{"peers":4,"direct":3,"relay":1,"paths":5}}

  Everything is best effort: a missing cgroup or a failing zerotier-cli only
  drops that field, it never stops the loop.
*/

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

const INTERVAL_MS = Math.max(2000, Number(process.env.STATS_INTERVAL_MS) || 15000);
const STATS_FILE = process.env.STATS_FILE || '/app/config/runtime-stats.json';
const ZT_HOME = process.env.ZT_HOME || '/var/lib/zerotier-one';
const ZT_PORT = String(process.env.ZT_PORT || '9994');
const ZT_CLI = process.env.ZT_CLI || '/usr/sbin/zerotier-cli';

function readFirstLine(file) {
  try {
    return fs.readFileSync(file, 'utf8').split('\n')[0];
  } catch (err) {
    return '';
  }
}

function numberOrNull(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : null;
}

// --- CPU -------------------------------------------------------------------
// Preference order: cgroup v2 cpu.stat, cgroup v1 cpuacct, /proc/stat.

function readCgroupUsageUsec() {
  const v2 = readFirstLine('/sys/fs/cgroup/cpu.stat');
  if (v2) {
    const m = /^usage_usec\s+(\d+)/m.exec(v2);
    if (m) return Number(m[1]);
  }
  const v1 = readFirstLine('/sys/fs/cgroup/cpuacct/cpuacct.usage');
  if (v1 && /^\d+$/.test(v1.trim())) return Math.round(Number(v1.trim()) / 1000);
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

function cpuPercent(prev, now, elapsedMs) {
  if (elapsedMs <= 0) return null;
  if (now.usageUsec !== null && prev.usageUsec !== null) {
    // Share of a single core, the way `docker stats` reports it.
    return round1(((now.usageUsec - prev.usageUsec) / 1000 / elapsedMs) * 100);
  }
  if (now.proc && prev.proc) {
    const dTotal = now.proc.total - prev.proc.total;
    const dIdle = now.proc.idle - prev.proc.idle;
    if (dTotal > 0) return round1(((dTotal - dIdle) / dTotal) * 100);
  }
  return null;
}

// --- memory ----------------------------------------------------------------

function readMemory() {
  const read = (file) => {
    try {
      return fs.readFileSync(file, 'utf8').trim();
    } catch (err) {
      return '';
    }
  };

  let used = numberOrNull(read('/sys/fs/cgroup/memory.current'));
  let total = numberOrNull(read('/sys/fs/cgroup/memory.max'));
  if (used === null) {
    used = numberOrNull(read('/sys/fs/cgroup/memory/memory.usage_in_bytes'));
    total = numberOrNull(read('/sys/fs/cgroup/memory/memory.limit_in_bytes'));
  }
  if (used === null) {
    // No cgroup at all (running outside a container): fall back to the host.
    const info = (() => {
      try {
        return fs.readFileSync('/proc/meminfo', 'utf8');
      } catch (err) {
        return '';
      }
    })();
    const mTotal = /^MemTotal:\s+(\d+) kB/m.exec(info);
    const mAvail = /^MemAvailable:\s+(\d+) kB/m.exec(info);
    if (!mTotal) return null;
    total = Number(mTotal[1]) * 1024;
    used = mAvail ? total - Number(mAvail[1]) * 1024 : null;
  }
  // "max" (cgroup v2) or a huge sentinel (cgroup v1) means "no limit".
  if (total === null || total === Infinity || total <= 0) total = os.totalmem();
  if (total > os.totalmem()) total = os.totalmem();
  if (used === null) return null;
  return {
    used: Math.max(0, used),
    total,
    percent: total > 0 ? round1((used / total) * 100) : null
  };
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

function round1(n) {
  return Math.round(n * 10) / 10;
}

let previous = null;

async function sample() {
  const started = Date.now();
  const usageUsec = readCgroupUsageUsec();
  const proc = usageUsec === null ? readProcStat() : null;
  const now = { usageUsec, proc };

  const snapshot = {
    collected_at: Math.floor(started / 1000),
    interval_ms: INTERVAL_MS,
    cpu: { percent: null, cores: os.cpus().length || 1 },
    mem: readMemory(),
    net: null
  };

  if (previous) {
    snapshot.cpu.percent = cpuPercent(previous, now, started - previous.at);
  }
  previous = Object.assign({ at: started }, now);

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
