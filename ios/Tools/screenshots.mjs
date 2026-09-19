// Canonical iOS screenshots: one command, deterministic, no grill attached.
//
// Drives the app's own build in the simulator and replays a cook file through
// it (PITBOSS_REPLAY), so the populated views are produced by the real parsing
// and rendering path rather than staged. Shots land in docs/screenshots/ios/.
//
//   node ios/Tools/screenshots.mjs
//
// NOTE: the default fixture is SYNTHETIC (ios/Tools/make-fixture-cook.mjs).
// Pass a real recorded cook to document real behaviour:
//   node ios/Tools/screenshots.mjs /path/to/a/real/cook.jsonl
import { execFileSync } from 'node:child_process';
import { mkdirSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const OUT = resolve(ROOT, 'docs/screenshots/ios');
const DEVICE = process.env.PITBOSS_SIM ?? 'iPhone 17 Pro';
const BUNDLE = 'com.openkb.pit-boss.ios';
const DERIVED = '/tmp/pbsim';
const COOK = process.argv[2] ?? '/tmp/fixture-cook.jsonl';

const env = { ...process.env, DEVELOPER_DIR: '/Applications/Xcode.app/Contents/Developer' };
const run = (cmd, args, opts = {}) =>
  execFileSync(cmd, args, { env, stdio: 'pipe', encoding: 'utf8', ...opts });

function step(n, total, msg) { console.log(`[${n}/${total}] ${msg}`); }

mkdirSync(OUT, { recursive: true });

if (!existsSync(COOK)) {
  step(1, 6, `generating fixture cook → ${COOK}`);
  run('node', [resolve(ROOT, 'ios/Tools/make-fixture-cook.mjs'), COOK]);
} else {
  step(1, 6, `using cook ${COOK}`);
}

step(2, 6, 'building for the simulator');
run('xcodebuild', [
  '-project', resolve(ROOT, 'ios/App/PitBoss.xcodeproj'),
  '-scheme', 'PitBoss', '-sdk', 'iphonesimulator',
  '-destination', `platform=iOS Simulator,name=${DEVICE}`,
  '-derivedDataPath', DERIVED, 'build',
]);

step(3, 6, `booting ${DEVICE}`);
try { run('xcrun', ['simctl', 'boot', DEVICE]); } catch { /* already booted */ }
run('open', ['-a', 'Simulator']);

step(4, 6, 'installing');
run('xcrun', ['simctl', 'install', DEVICE,
  `${DERIVED}/Build/Products/Debug-iphonesimulator/PitBoss.app`]);

const shots = [
  { name: 'dashboard-light', appearance: 'light' },
  { name: 'dashboard-dark', appearance: 'dark' },
];

let n = 5;
for (const shot of shots) {
  step(n++, 6, `capturing ${shot.name}`);
  run('xcrun', ['simctl', 'ui', DEVICE, 'appearance', shot.appearance]);
  try { run('xcrun', ['simctl', 'terminate', DEVICE, BUNDLE]); } catch { /* not running */ }
  run('xcrun', ['simctl', 'launch', DEVICE, BUNDLE], {
    env: { ...env, SIMCTL_CHILD_PITBOSS_REPLAY: COOK, SIMCTL_CHILD_PITBOSS_REPLAY_RATE: '200' },
  });
  // Let the replay fill the curve before capturing.
  execFileSync('sleep', ['14']);
  run('xcrun', ['simctl', 'io', DEVICE, 'screenshot', `${OUT}/${shot.name}.png`]);
}

try { run('xcrun', ['simctl', 'terminate', DEVICE, BUNDLE]); } catch { /* */ }
console.log(`\n✓ wrote ${shots.length} shots to docs/screenshots/ios/`);
