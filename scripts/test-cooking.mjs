// The cooking knowledge base, checked against the same assertions the Swift
// harness makes (ios/PitBossKit/Sources/pitboss-verify, "Shared cooking data"
// and "Meat catalogue"). Both apps read data/cooking.json; these are the
// claims about it that have actual stakes — the food-safety floors.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const C = await import(path.join(ROOT, 'dist/shared/cooking.js'));

const data = C.parseCooking(JSON.parse(fs.readFileSync(path.join(ROOT, 'data/cooking.json'), 'utf8')));

let pass = 0, fail = 0;
const ok = (cond, msg) => {
  if (cond) { pass++; } else { fail++; console.log(`  FAIL ${msg}`); }
};
const eq = (a, b, msg) => ok(a === b, `${msg} (got ${JSON.stringify(a)}, want ${JSON.stringify(b)})`);

console.log('\nCooking knowledge base\n');

// --- structure ---
ok(data.cuts.length > 30, `the catalogue is worth having, got ${data.cuts.length} cuts`);
ok(new Set(data.cuts.map(C.cutId)).size === data.cuts.length, 'cut ids are unique');

for (const cut of data.cuts) {
  ok(cut.targets.length > 0, `${cut.name} has at least one target`);
  ok(C.suggestedTarget(cut) !== null, `${cut.name} has a suggested target`);
  for (const t of cut.targets) {
    // Nothing plausible falls outside this band; a typo would.
    ok(t.temperature >= 90 && t.temperature <= 215,
      `${cut.name} · ${t.label} = ${t.temperature}° is plausible`);
  }
}

// Every method a cut references resolves (parseCooking throws otherwise, so
// reaching here already proves it) and every named method has steps.
const names = new Set(data.methods.map((m) => m.name));
for (const n of ['3-2-1', '2-2-1', '0 to 400', 'Texas crutch', 'Reverse sear', 'Spatchcock', 'Hot and fast']) {
  ok(names.has(n) && C.findMethod(data, n).steps.length > 0, `${n} resolves from the data file`);
}

// --- food safety: the assertions with stakes ---
for (const cut of C.cutsByCategory(data, 'poultry')) {
  ok(cut.targets.some((t) => t.temperature >= 165 && t.kind === 'safeMinimum'),
    `${cut.name} offers the 165° poultry safe minimum`);
}
for (const cut of C.cutsByCategory(data, 'ground')) {
  ok(cut.targets.some((t) => t.kind === 'safeMinimum' && t.temperature >= 160),
    `${cut.name} offers a ground-meat safe minimum of at least 160°`);
}
ok(C.isBelowSafeMinimumForCategory({ label: 'Medium rare', temperature: 135, kind: 'doneness' }, 'poultry', data),
  '135° would be flagged for poultry');

// The per-cut override, which is what the category floor alone got wrong.
const ham = data.cuts.find((c) => c.name.includes('fully cooked'));
if (ham) {
  eq(C.safeFloor(ham, data), 140, "a fully-cooked ham's floor is 140°, not raw pork's 145°");
  ok(!C.isBelowSafeMinimum({ label: 'Reheated', temperature: 140, kind: 'safeMinimum' }, ham, data),
    "140° is not below a fully-cooked ham's own floor");
}
const chops = data.cuts.find((c) => c.name === 'Pork chops');
if (chops) eq(C.safeFloor(chops, data), 145, 'raw pork still uses the 145° floor');

// --- brisket portions ---
const briskets = data.cuts.filter((c) => c.name.startsWith('Brisket'));
eq(briskets.length, 3, 'brisket is split into packer, flat and point');
for (const cut of briskets) {
  eq(C.suggestedTarget(cut).kind, 'texture', `${cut.name} suggests a texture temp`);
  ok(cut.note !== undefined, `${cut.name} explains how its portion differs`);
}
const flat = briskets.find((c) => c.name.includes('flat'));
const point = briskets.find((c) => c.name.includes('point'));
const packer = briskets.find((c) => c.name.includes('packer'));
if (flat && point && packer) {
  eq(C.suggestedTarget(flat).temperature, 200, 'the lean flat is pulled at 200°');
  eq(C.suggestedTarget(point).temperature, 205, 'the fatty point goes to 205°');
  ok(C.suggestedTarget(flat).temperature < C.suggestedTarget(point).temperature,
    'the flat comes off before the point');
  const p = C.suggestedTarget(packer).temperature;
  ok(p >= C.suggestedTarget(flat).temperature && p <= C.suggestedTarget(point).temperature,
    'a whole packer sits between its two muscles');
}
const breast = data.cuts.find((c) => c.name === 'Chicken breast');
if (breast) eq(C.suggestedTarget(breast).temperature, 165, 'chicken breast suggests 165°');

// --- search + presets ---
ok(C.searchCuts(data, 'brisket').length > 0, 'search finds brisket');
ok(C.searchCuts(data, 'POULTRY').length > 0, 'search is case-insensitive and matches category');
eq(C.searchCuts(data, '').length, data.cuts.length, 'an empty search returns everything');
eq(C.searchCuts(data, 'zzzz').length, 0, 'a nonsense search returns nothing');
ok(C.presetableCuts(data).length > 15, 'enough cuts carry a grill temperature');

// Method durations.
eq(C.methodDurationLabel(C.findMethod(data, '3-2-1')), '~6h', '3-2-1 totals six hours');
eq(C.methodTotalMinutes(C.findMethod(data, 'Texas crutch')), null,
  'a method without per-stage times declares no total');

console.log(`${fail === 0 ? 'ALL PASS' : `${fail} FAILED`} — ${pass} checks\n`);
process.exit(fail === 0 ? 0 : 1);
