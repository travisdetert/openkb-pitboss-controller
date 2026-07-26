// Freeze python/sidecar.py into a self-contained binary (dist-sidecar/sidecar)
// via PyInstaller, so the packaged app needs no system Python or relocatable venv
// (see ADR 0005). Run automatically by `npm run pack`.
import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { join } from 'node:path';

const root = process.cwd();
const isWin = process.platform === 'win32';
const venvPy = join(root, '.venv', isWin ? 'Scripts' : 'bin', isWin ? 'python.exe' : 'python');

if (!existsSync(venvPy)) {
  console.error('✗ .venv not found — run `npm run setup` first.');
  process.exit(1);
}

function run(label, args) {
  console.log(`\n[build:sidecar] ${label}`);
  const r = spawnSync(venvPy, args, { stdio: 'inherit', cwd: root });
  if (r.error) { console.error('✗', r.error.message); process.exit(1); }
  if (r.status !== 0) { console.error(`✗ failed (exit ${r.status})`); process.exit(1); }
}

// PyInstaller is a build-time tool, not a runtime dep — install it into the venv on demand.
run('Ensuring PyInstaller is available…', ['-m', 'pip', 'install', '--quiet', 'pyinstaller']);
run('Freezing python/sidecar.py → dist-sidecar/sidecar…', [
  '-m', 'PyInstaller', '--onefile', '--name', 'sidecar', '--noconfirm',
  '--distpath', 'dist-sidecar', '--workpath', 'build/sidecar', '--specpath', 'build/sidecar',
  '--collect-all', 'bleak', '--collect-all', 'pytboss',
  'python/sidecar.py',
]);

console.log('\n✓ dist-sidecar/sidecar built (self-contained — no system Python needed).');
