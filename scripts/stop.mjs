#!/usr/bin/env node
// Stop this project's Electron app cleanly.
//
// Exists because an ad-hoc process sweep is a footgun twice over: it reaches
// other projects' Electron apps, and — the subtler one — a naive pattern
// usually matches only the *helper* processes (GPU, renderer, utility) while
// the main process survives, still holding the Bluetooth connection. That is
// exactly how a "stopped" app goes on owning the grill.
//
// So: match only processes whose command line contains THIS project's path,
// stop the main process first (helpers exit with it), ask politely before
// insisting, and report what was actually stopped.
//
//   npm run stop
import { execFileSync } from 'node:child_process';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');

/** Processes belonging to this project, main process first. */
function findProcesses() {
  let out = '';
  try {
    out = execFileSync('ps', ['-Ao', 'pid=,command='], { encoding: 'utf8' });
  } catch {
    return [];
  }
  return out
    .split('\n')
    .map((line) => {
      const m = line.match(/^\s*(\d+)\s+(.*)$/);
      return m ? { pid: Number(m[1]), command: m[2] } : null;
    })
    .filter((p) => p && p.command.includes(ROOT) && /electron/i.test(p.command))
    // Helpers carry --type=; the main process does not. Stop the main one
    // first — the helpers go with it.
    .sort((a, b) =>
      Number(a.command.includes('--type=')) - Number(b.command.includes('--type=')));
}

function alive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
}

const found = findProcesses();
if (found.length === 0) {
  console.log('Nothing to stop — no Electron process for this project is running.');
  process.exit(0);
}

const mains = found.filter((p) => !p.command.includes('--type='));
console.log(
  `Stopping ${found.length} process(es) — ${mains.length} main, ${found.length - mains.length} helper.`);

for (const p of found) {
  try {
    process.kill(p.pid, 'SIGTERM');
  } catch {
    /* already gone */
  }
}

// Give them a moment to shut down properly: the app runs a graceful teardown
// (disconnecting BLE, closing the cook file) that is worth waiting for.
const deadline = Date.now() + 5000;
while (Date.now() < deadline && found.some((p) => alive(p.pid))) {
  execFileSync('sleep', ['0.2']);
}

const stubborn = found.filter((p) => alive(p.pid));
for (const p of stubborn) {
  console.log(`  ${p.pid} ignored SIGTERM — sending SIGKILL.`);
  try {
    process.kill(p.pid, 'SIGKILL');
  } catch {
    /* raced */
  }
}

const remaining = findProcesses();
console.log(remaining.length === 0
  ? 'Stopped.'
  : `Warning: ${remaining.length} process(es) still running.`);
