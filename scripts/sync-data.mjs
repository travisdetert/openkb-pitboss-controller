// Keep the vendored copies of data/ in step with the source of truth.
//
// `data/` holds the files both apps read (ADR 0007). The desktop loads them at
// runtime from dist/; Swift can only read a file that lives inside its own
// target, so those copies are checked in. A checked-in copy with nothing
// enforcing it is a copy that drifts — a corrected safety temperature fixed in
// data/ and not in the bundle is exactly the failure ADR 0007 exists to
// prevent, and it would be invisible until someone compared them by hand.
//
//   node scripts/sync-data.mjs           update the vendored copies
//   node scripts/sync-data.mjs --check   fail if any has drifted (used by npm test)
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');

const COPIES = [
  { from: 'data/cooking.json', to: 'ios/PitBossKit/Sources/PitBossKit/Resources/cooking.json' },
  { from: 'data/estimate-vectors.json', to: 'ios/PitBossKit/Sources/pitboss-verify/estimate-vectors.json' },
];

const check = process.argv.includes('--check');
const digest = (p) => crypto.createHash('sha256').update(fs.readFileSync(p)).digest('hex');

let drifted = 0;
for (const { from, to } of COPIES) {
  const src = path.join(ROOT, from), dst = path.join(ROOT, to);
  if (!fs.existsSync(src)) {
    console.error(`  MISSING source ${from}`);
    drifted++;
    continue;
  }
  const same = fs.existsSync(dst) && digest(src) === digest(dst);
  if (same) {
    console.log(`  ok   ${to} matches ${from}`);
  } else if (check) {
    console.error(`  DRIFT ${to} does not match ${from} — run: npm run data:sync`);
    drifted++;
  } else {
    fs.mkdirSync(path.dirname(dst), { recursive: true });
    fs.copyFileSync(src, dst);
    console.log(`  synced ${from} -> ${to}`);
  }
}

if (check && drifted > 0) {
  console.error(`\n${drifted} vendored copy/copies out of date.\n`);
  process.exit(1);
}
console.log(check ? '\nALL PASS — vendored data is in step\n' : '\nData synced.\n');
