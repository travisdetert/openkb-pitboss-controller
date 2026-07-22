// One-command setup for a fresh checkout: installs the JS deps, then creates the
// Python venv and installs the pinned BLE stack. Idempotent — safe to re-run.
// Uses only Node built-ins so it works before `npm install` has run.
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const root = process.cwd();
const isWin = process.platform === 'win32';
const venv = join(root, '.venv');
const venvPy = join(venv, isWin ? 'Scripts' : 'bin', isWin ? 'python.exe' : 'python');

let step = 0;
const total = 3;
const say = (msg) => console.log(`\n[setup ${++step}/${total}] ${msg}`);
const ok = (msg) => console.log(`  ✓ ${msg}`);
const die = (msg) => { console.error(`\n✗ ${msg}\n`); process.exit(1); };

function run(cmd, args, opts = {}) {
  const r = spawnSync(cmd, args, { stdio: 'inherit', cwd: root, ...opts });
  if (r.error) die(`could not run \`${cmd}\`: ${r.error.message}`);
  if (r.status !== 0) die(`\`${cmd} ${args.join(' ')}\` failed (exit ${r.status})`);
}

// Find a Python 3 interpreter (python3, then python).
function findPython() {
  for (const c of ['python3', 'python']) {
    const r = spawnSync(c, ['--version'], { encoding: 'utf8' });
    if (r.status === 0 && /Python 3\./.test((r.stdout || '') + (r.stderr || ''))) return c;
  }
  return null;
}

console.log('Setting up openkb-pitboss-controller…');

// 1. JS dependencies (Electron, TypeScript, …)
say('Installing Node dependencies (npm install)…');
run(isWin ? 'npm.cmd' : 'npm', ['install']);
ok('Node dependencies installed');

// 2. Python venv
say('Creating the Python virtual environment (.venv)…');
const py = findPython();
if (!py) die('Python 3 not found. Install Python 3.11+ (macOS: `brew install python`) and re-run `npm run setup`.');
if (existsSync(venvPy)) {
  ok('.venv already exists — reusing it');
} else {
  run(py, ['-m', 'venv', '.venv']);
  ok('.venv created');
}

// 3. Python dependencies (the pinned BLE stack)
say('Installing Python dependencies (requirements.txt)…');
run(venvPy, ['-m', 'pip', 'install', '--quiet', '--upgrade', 'pip']);
run(venvPy, ['-m', 'pip', 'install', '-r', 'requirements.txt']);
ok('Python dependencies installed');

console.log('\n✓ Setup complete. Next: `npm start` — the first-run wizard will find your grill.\n');
