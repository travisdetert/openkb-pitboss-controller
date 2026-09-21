// Regenerate docs/screenshots/ from the manifest in screenshots.config.mjs.
//
// Drives the app's own Electron with a replayed cook, so every image comes from
// the real renderer with real data and no hardware attached. Same inputs, same
// output — a screenshot taken by hand is worse than none, because it rots on
// the next UI change and can't be regenerated.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const cfg = (await import(pathToFileURL(path.join(ROOT, 'screenshots.config.mjs')))).default;

const outDir = path.join(ROOT, cfg.outDir);
fs.mkdirSync(outDir, { recursive: true });

// The app reads its theme from settings.json, so a themed shot needs that file
// set before launch and restored after. Touching the user's real settings is
// the one unavoidable side effect; it is saved and put back even on failure.
const settingsPath = path.join(os.homedir(),
  'Library', 'Application Support', 'openkb-pit-boss', 'settings.json');
const hadSettings = fs.existsSync(settingsPath);
const savedSettings = hadSettings ? fs.readFileSync(settingsPath, 'utf8') : null;

function setTheme(theme) {
  if (!hadSettings) return;
  const s = JSON.parse(savedSettings);
  s.theme = theme;
  fs.writeFileSync(settingsPath, JSON.stringify(s, null, 2));
}

function capture(shot) {
  return new Promise((resolve, reject) => {
    const out = path.join(outDir, `${shot.name}.png`);
    const child = spawn('npx', ['electron', '.'], {
      cwd: ROOT,
      env: {
        ...process.env,
        PITBOSS_REPLAY: path.join(ROOT, cfg.replay),
        PITBOSS_REPLAY_RATE: String(cfg.rate),
        PITBOSS_SHOT: out,
        PITBOSS_SHOT_DELAY: String(cfg.settleMs),
        ...(shot.click ? { PITBOSS_SHOT_CLICK: shot.click.join(',') } : {}),
        ...(shot.btBlocked ? { PITBOSS_BT_BLOCKED: shot.btBlocked } : {}),
      },
      stdio: 'ignore',
    });
    // The app stays up after capturing; give it the settle time plus headroom,
    // then stop it. A bounded wait, not a hang — see "observable progress".
    const timer = setTimeout(() => { child.kill('SIGTERM'); }, cfg.settleMs + 12_000);
    child.on('exit', () => {
      clearTimeout(timer);
      fs.existsSync(out) ? resolve(out) : reject(new Error(`no image written for ${shot.name}`));
    });
  });
}

let failed = 0;
try {
  for (const [i, shot] of cfg.shots.entries()) {
    process.stdout.write(`  [${i + 1}/${cfg.shots.length}] ${shot.name} (${shot.theme})… `);
    setTheme(shot.theme);
    try {
      await capture(shot);
      console.log('ok');
    } catch (e) {
      failed++;
      console.log(`FAILED — ${e.message}`);
    }
  }
} finally {
  if (savedSettings !== null) fs.writeFileSync(settingsPath, savedSettings);
}

console.log(failed === 0
  ? `\n${cfg.shots.length} screenshots written to ${cfg.outDir}/\n`
  : `\n${failed} shot(s) failed\n`);
process.exit(failed === 0 ? 0 : 1);
