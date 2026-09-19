// Proves the Swift CookStore writes the same JSONL the desktop recorder reads.
//
// The iOS port deliberately uses the desktop's on-disk cook format so a file
// from a phone opens in the desktop app. That claim is only worth making if it
// is checked, so this parses a Swift-written file with the *desktop's* own
// readCook logic (src/main/recorder.ts) rather than a lookalike.
//
//   swift run pitboss-verify          # writes /tmp/pitboss-interop.jsonl
//   node ios/Tools/check-interop.mjs
import { readFileSync } from 'node:fs';

const FILE = process.argv[2] ?? '/tmp/pitboss-interop.jsonl';

// Verbatim from src/main/recorder.ts — the id shape guard and the line filter.
const COOK_ID_RE = /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$/;
function readCook(raw) {
  const out = [];
  for (const line of raw.split('\n')) {
    if (!line.trim()) continue;
    try {
      const obj = JSON.parse(line);
      if (typeof obj.t === 'number') out.push(obj);
    } catch { /* skip malformed line */ }
  }
  return out;
}

let failures = 0;
const check = (name, cond) => {
  console.log(`  ${cond ? 'ok  ' : 'FAIL'} ${name}`);
  if (!cond) failures++;
};

let raw;
try {
  raw = readFileSync(FILE, 'utf8');
} catch {
  console.error(`missing ${FILE} — run 'swift run pitboss-verify' first`);
  process.exit(2);
}

const lines = raw.split('\n').filter((l) => l.trim());
const meta = JSON.parse(lines[0]);
const end = JSON.parse(lines[lines.length - 1]);
const samples = readCook(raw);

console.log(`desktop reader parsing a Swift-written cook (${lines.length} lines)`);
check('first line is a meta record', meta.type === 'meta');
check('meta carries an epoch-ms startedAt', Number.isInteger(meta.startedAt));
check('last line is an end record', end.type === 'end');
check('end carries an epoch-ms endedAt', Number.isInteger(end.endedAt));
check('desktop readCook() finds samples', samples.length > 0);

const s = samples[0];
check('sample has epoch-ms t', Number.isInteger(s.t));
check('grillTemp present (number or null)', 'grillTemp' in s);
check('grillSetTemp present (number or null)', 'grillSetTemp' in s);
check('all four probe fields present', [1, 2, 3, 4].every((i) => `p${i}Temp` in s));
check('absent probes are null, not missing or 0', s.p3Temp === null && s.p4Temp === null);
check('component activity present', typeof s.auger === 'boolean'
  && typeof s.fan === 'boolean' && typeof s.igniter === 'boolean');
check('cook id shape matches the desktop guard',
  COOK_ID_RE.test(new Date(meta.startedAt).toISOString().replace(/:/g, '-').replace(/\..+$/, '')));
check('samples are ordered by time',
  samples.every((x, i) => i === 0 || x.t >= samples[i - 1].t));

// A cook with interruption events must still read cleanly on the desktop.
// Event lines deliberately use `at` rather than `t`, because the desktop keeps
// any line with a numeric `t` as a sample — an event using `t` would be
// silently misread as a temperature reading.
try {
  const withEvents = readFileSync('/tmp/pitboss-interop-events.jsonl', 'utf8');
  const eventLines = withEvents.split('\n').filter((l) => l.includes('"type":"event"'));
  const parsed = readCook(withEvents);
  console.log(`\ndesktop reader against a cook with ${eventLines.length} interruption events`);
  check('the file contains event lines', eventLines.length > 0);
  check('no event line carries a `t` key', eventLines.every((l) => !JSON.parse(l).t));
  check('desktop readCook ignores events entirely',
    parsed.every((s) => s.type === undefined));
  check('samples are still recovered alongside events', parsed.length > 0);
  check('every recovered sample is a real reading',
    parsed.every((s) => Number.isInteger(s.t) && 'grillTemp' in s));
} catch (e) {
  if (e.code === 'ENOENT') console.log('\n(skipped events check — no events fixture)');
  else throw e;
}

console.log(failures === 0 ? '\n✓ the desktop reads Swift-written cooks' : `\n✗ ${failures} failure(s)`);
process.exit(failures === 0 ? 0 : 1);
