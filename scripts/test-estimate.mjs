// Run the shared estimator golden vectors (data/estimate-vectors.json) against
// the TypeScript implementation.
//
// The same file drives the Swift implementation in pitboss-verify, so the two
// ports are held to one contract: change the behaviour in one app without
// changing it in the other and this fails. See ADR 0007.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const est = await import(path.join(ROOT, 'dist/shared/estimate.js'));

const spec = JSON.parse(fs.readFileSync(path.join(ROOT, 'data/estimate-vectors.json'), 'utf8'));
const EPOCH_MS = spec.sampleSpec.epochSeconds * 1000;
const STRIDE = spec.sampleSpec.strideMinutes;

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; console.log(`  ok   ${msg}`); }
  else { fail++; console.log(`  FAIL ${msg}`); }
};

// Swift's .rounded() is half-away-from-zero; Math.round is half-up. The vector
// file pins the rule, so implement it rather than inherit the platform's.
const roundHalfAway = (x) => Math.sign(x) * Math.round(Math.abs(x));

function buildSamples(climb, probe) {
  if (!climb) return [];
  const out = [];
  for (let m = 0; m <= climb.minutes; m += STRIDE) {
    const value = climb.from + roundHalfAway((climb.perHour * m) / 60);
    const s = {
      t: EPOCH_MS + m * 60_000,
      grillTemp: 250, grillSetTemp: 250,
      p1Temp: null, p2Temp: null, p3Temp: null, p4Temp: null,
      auger: false, fan: true, igniter: false,
    };
    s[`p${probe}Temp`] = value;
    out.push(s);
  }
  return out;
}

function run(c) {
  // Samples always carry probe 1; a case asking about another probe is testing
  // that it doesn't borrow probe 1's data.
  const samples = buildSamples(c.climb, 1);
  const now = EPOCH_MS + c.nowMinutes * 60_000;
  const events = (c.events ?? []).map((e) => ({ at: EPOCH_MS + e.atMinutes * 60_000, kind: e.kind }));
  return est.estimate(samples, c.probe, c.target, events, now);
}

console.log('\nCook time estimates (shared vectors)\n');
const verdicts = new Map();
for (const c of spec.cases) verdicts.set(c.name, run(c));

for (const c of spec.cases) {
  const v = verdicts.get(c.name);
  const e = c.expect;
  const now = EPOCH_MS + c.nowMinutes * 60_000;

  ok(v.kind === e.kind, `${c.name} — ${e.kind}${v.kind === e.kind ? '' : ` (got ${v.kind})`}`);
  if (v.kind !== e.kind) continue;

  if (e.phase !== undefined) ok(v.phase === e.phase, `  phase ${e.phase}`);
  if (e.ratePerHour) {
    ok(Math.abs(v.ratePerHour - e.ratePerHour.approx) < e.ratePerHour.tolerance,
      `  rate ~${e.ratePerHour.approx}°/hr (got ${v.ratePerHour.toFixed(2)})`);
  }
  if (e.allowances !== undefined) {
    const kinds = v.allowances.map((a) => a.type).sort();
    ok(JSON.stringify(kinds) === JSON.stringify([...e.allowances].sort()),
      `  allowances [${e.allowances.join(', ')}]${kinds.length ? ` (got [${kinds.join(', ')}])` : ''}`);
  }
  if (e.minHours !== undefined) {
    ok(v.seconds / 3600 > e.minHours, `  over ${e.minHours}h (got ${(v.seconds / 3600).toFixed(1)}h)`);
  }
  if (e.labelPrefix !== undefined) {
    ok((est.estimateLabel(v) ?? '').startsWith(e.labelPrefix), `  label is hedged`);
  }
  if (e.finishTimeAhead) ok(est.finishTime(v, now) > now, `  finish time is ahead`);
  if (e.sinceSeconds !== undefined) {
    ok(v.sinceSeconds === e.sinceSeconds, `  flat for ${e.sinceSeconds}s`);
  }
  if (e.sinceMinutesAtLeast !== undefined) {
    ok(v.sinceSeconds >= e.sinceMinutesAtLeast * 60,
      `  flat for >= ${e.sinceMinutesAtLeast}m (got ${Math.round(v.sinceSeconds / 60)}m)`);
  }
  if (e.noLabel) ok(est.estimateLabel(v) === null, `  no number to show`);
  if (e.explanationContains !== undefined) {
    ok((est.explanation(v) ?? '').includes(e.explanationContains),
      `  explained: "${e.explanationContains}"`);
  }
  if (e.secondsDeltaVs) {
    const base = verdicts.get(e.secondsDeltaVs.case);
    if (!base || base.kind !== 'eta') {
      ok(false, `  baseline case "${e.secondsDeltaVs.case}" is not an eta`);
    } else {
      const delta = v.seconds - base.seconds;
      ok(Math.abs(delta - e.secondsDeltaVs.delta) < e.secondsDeltaVs.tolerance,
        `  ${e.secondsDeltaVs.delta / 60}m vs baseline (got ${Math.round(delta / 60)}m)`);
    }
  }
}

console.log(`\n${fail === 0 ? 'ALL PASS' : `${fail} FAILED`} — ${pass} checks\n`);
process.exit(fail === 0 ? 0 : 1);
