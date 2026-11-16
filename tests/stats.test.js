#!/usr/bin/env node
/*
  Checks for the overview runtime metrics: the collector writes a well-formed
  snapshot, the reader hides stale values, and the overview view renders those
  numbers (including the "no data yet" state).
*/

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const root = path.join(__dirname, '..');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'ztp-stats-'));

function writeStats(file, payload) {
  fs.writeFileSync(file, JSON.stringify(payload));
}

async function collectSnapshot() {
  const file = path.join(tmp, 'collected.json');
  const child = spawn(process.execPath, [path.join(root, 'patch', 'stats-collector.js')], {
    env: Object.assign({}, process.env, {
      STATS_FILE: file,
      STATS_INTERVAL_MS: '2000',
      ZT_CLI: '/bin/false',
      ZT_PORT: '9994',
      ZT_HOME: tmp
    }),
    stdio: 'ignore'
  });

  const deadline = Date.now() + 8000;
  let payload = null;
  while (Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 250));
    try {
      payload = JSON.parse(fs.readFileSync(file, 'utf8'));
      break;
    } catch (err) {
      /* not written yet */
    }
  }
  child.kill('SIGTERM');
  return payload;
}

(async function main() {
  // 1. The collector produces a snapshot even without a working zerotier-cli.
  const collected = await collectSnapshot();
  assert(collected, 'collector did not write a snapshot');
  assert(typeof collected.collected_at === 'number', 'collected_at missing');
  assert(collected.cpu && typeof collected.cpu.cores === 'number', 'cpu.cores missing');
  assert('appPercent' in collected.cpu, 'cpu.appPercent missing');
  assert(collected.interval_ms === 2000, 'interval_ms should echo the requested interval');
  assert(collected.mem && typeof collected.mem.used === 'number' && collected.mem.total > 0, 'mem missing');
  assert(collected.net === null, 'net should be null when zerotier-cli fails');

  const statsFile = path.join(tmp, 'runtime-stats.json');
  fs.writeFileSync(
    statsFile,
    JSON.stringify({
      collected_at: Math.floor(Date.now() / 1000),
      cpu: { percent: 12.5, cores: 8, appPercent: 3.1, limitCores: 2 },
      mem: {
        used: 6 * 1024 * 1024 * 1024, total: 16 * 1024 * 1024 * 1024, percent: 37.5,
        appUsed: 128 * 1024 * 1024, appLimit: 512 * 1024 * 1024
      },
      net: { peers: 5, direct: 4, relay: 1, paths: 7 }
    })
  );

  process.env.RUNTIME_STATS_FILE = statsFile;
  const stats = require(path.join(root, 'patch', 'ztncui', 'stats.js'));

  // 2. Fresh data is summarised with the units the template prints.
  let summary = stats.summarise(stats.read());
  assert.strictEqual(summary.available, true, 'fresh snapshot should be available');
  assert.strictEqual(summary.cpuPercent, 12.5, 'host CPU is the headline figure');
  assert.strictEqual(summary.cores, 8);
  assert.strictEqual(summary.cpuAppPercent, 3.1, 'container share is secondary');
  assert.strictEqual(summary.limitCores, 2);
  assert.strictEqual(summary.memUsedMb, 6144, 'host memory is the headline figure');
  assert.strictEqual(summary.memTotalMb, 16384);
  assert.strictEqual(summary.memPercent, 37.5);
  assert.strictEqual(summary.memAppMb, 128, 'container memory is secondary');
  assert.strictEqual(summary.memUsed, '6 GB', 'memory of a gigabyte or more is shown in GB');
  assert.strictEqual(summary.memTotal, '16 GB');
  assert.strictEqual(summary.memApp, '128 MB', 'memory under a gigabyte stays in MB');
  assert.strictEqual(stats.formatMemory(1536 * 1024 * 1024), '1.5 GB');
  assert.strictEqual(stats.formatMemory(1024 * 1024 * 1024), '1 GB');
  assert.strictEqual(stats.formatMemory(1023 * 1024 * 1024), '1023 MB');
  assert.strictEqual(stats.formatMemory(null), null);
  assert.strictEqual(summary.peers, 5);
  assert.strictEqual(summary.relay, 1);

  // 3. An old snapshot is reported as unavailable rather than as "live".
  writeStats(statsFile, {
    collected_at: Math.floor(Date.now() / 1000) - 3600,
    cpu: { percent: 90, cores: 2 },
    mem: { used: 1, total: 2, percent: 50, appUsed: 1, appLimit: 2 },
    net: { peers: 1, direct: 1, relay: 0, paths: 1 }
  });
  summary = stats.summarise(stats.read());
  assert.strictEqual(summary.available, false, 'stale snapshot must not be available');
  assert.strictEqual(summary.cpuPercent, null);
  assert.strictEqual(summary.peers, null);

  // 4. A corrupt file falls back to the empty shape instead of throwing.
  fs.writeFileSync(statsFile, '{not json');
  summary = stats.summarise(stats.read());
  assert.strictEqual(summary.available, false);
  assert.strictEqual(summary.cpuPercent, null);

  // 5. The overview view renders both the populated and the empty state.
  // The template needs pug, which only exists once the dependencies are
  // installed. CI runs this file straight from the checkout (no npm install),
  // where the image itself already covers the rendered page; skip the render
  // assertions there instead of failing for a missing dev-time module.
  let pug = null;
  try {
    pug = require(path.join(root, 'patch', 'ztncui', 'node_modules', 'pug'));
  } catch (err) {
    console.log('  (view render checks skipped: pug is not installed)');
  }
  const locals = {
    t: (key) => key,
    locale: 'zh-CN',
    htmlLang: 'zh-CN',
    switchTo: [{ locale: 'en', label: 'English' }],
    navigate: { active: 'controller_home' },
    title: 'ztncui',
    zt_status: { address: '8056c2e21c', version: '1.16.2' }
  };
  const viewPath = path.join(root, 'patch', 'ztncui', 'views', 'index.pug');

  if (pug) {
    const populated = pug.renderFile(viewPath, Object.assign({}, locals, {
      stats: {
        available: true, cpuPercent: 12.5, cores: 8, cpuAppPercent: 3.1, limitCores: 2,
        memUsed: '6 GB', memTotal: '16 GB', memPercent: 37.5, memApp: '128 MB',
        memUsedMb: 6144, memTotalMb: 16384, memAppMb: 128,
        peers: 5, direct: 4, relay: 1, paths: 7
      }
    }));
    assert(populated.includes('data-stat="cpu"'), 'cpu metric missing');
    assert(populated.includes('data-bar="mem"'), 'memory meter missing');
    assert(populated.includes('data-stat="peers"'), 'peer metric missing');
    assert(populated.includes('12.5%'), 'cpu value missing');
    assert(populated.includes('data-stat="cpu-hint"'), 'cpu hint missing');
    assert(populated.includes('data-stat="mem-hint"'), 'memory hint missing');
    assert(populated.includes('overview.memHint'), 'the memory hint template should be rendered');
    assert(!populated.includes('card-grid'), 'the quick action cards should be gone');

    const empty = pug.renderFile(viewPath, Object.assign({}, locals, {
      stats: {
        available: false, cpuPercent: null, cores: null, cpuAppPercent: null, limitCores: null,
        memUsed: null, memTotal: null, memPercent: null, memApp: null,
        memUsedMb: null, memTotalMb: null, memAppMb: null,
        peers: null, direct: null, relay: null, paths: null
      }
    }));
    assert(empty.includes('overview.statsStale'), 'stale hint missing');
  }

  console.log('stats checks passed');
  fs.rmSync(tmp, { recursive: true, force: true });
})().catch((err) => {
  console.error(err && err.stack ? err.stack : err);
  process.exit(1);
});
