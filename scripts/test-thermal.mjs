// Unit test for the thermal-anomaly classifier (src/main/thermal.ts).
// Run after a build:  node scripts/test-thermal.mjs
// It exercises the pure classify/rate logic with synthetic temp series so the
// pellet/door detection is verifiable without a live grill.

import { classifyThermal, rateOverWindow, THERMAL } from '../dist/main/thermal.js';

let failures = 0;
function check(name, cond) {
  if (cond) { console.log(`  ok   ${name}`); }
  else { console.log(`  FAIL ${name}`); failures++; }
}

// Build a temp series: `points` evenly spaced every `stepMs`, ending at `now`.
function series(now, stepMs, values) {
  const n = values.length;
  return values.map((v, i) => ({ t: now - (n - 1 - i) * stepMs, v }));
}

const now = 1_000_000_000_000; // fixed clock (no Date.now)

// --- rateOverWindow ---------------------------------------------------------
{
  const hist = series(now, 5_000, [250, 245, 240, 235, 230, 225, 220, 215, 210, 205, 200, 195, 190]); // 60s span
  const r = rateOverWindow(hist, now, 60_000);
  // 250 -> 190 over 60s = -60°/min.
  check('rate: steep 60s drop ≈ -60/min', r !== null && Math.abs(r + 60) < 1);
  check('rate: null when span too short', rateOverWindow(series(now, 5_000, [250, 245]), now, 60_000) === null);
  check('rate: null on empty', rateOverWindow([], now, 60_000) === null);
}

// --- steady at temp: no alerts ---------------------------------------------
{
  const vals = [];
  for (let i = 0; i < 60; i++) vals.push(250 + (i % 2 === 0 ? 2 : -2)); // ±2 oscillation
  const hist = series(now, 5_000, vals);
  const v = classifyThermal({ now, hist, setTemp: 250, grillTemp: 250, atTemp: true, noPellets: false, doorActive: false });
  check('steady: no door', v.door === false);
  check('steady: no pellet', v.pellet === false);
}

// --- lid/door open: steep short drop ---------------------------------------
{
  // From 250 down to 205 over ~60s (-45°/min), now 45° below set.
  const hist = series(now, 5_000, [250, 244, 238, 232, 226, 220, 214, 210, 208, 206, 205, 205, 205]);
  const v = classifyThermal({ now, hist, setTemp: 250, grillTemp: 205, atTemp: true, noPellets: false, doorActive: false });
  check('door: steep drop flags door', v.door === true);
  check('door: not flagged as pellet while door active', v.pellet === false);
}

// --- out of pellets: slow sustained decline over 4 min ---------------------
{
  // 250 -> 205 over 4 min = ~-11°/min sustained; dev 45 (>=40). Short-window
  // rate is also ~-11/min, which is NOT steep enough for the door rule (-25).
  const vals = [];
  for (let i = 0; i <= 48; i++) vals.push(Math.round(250 - i * (45 / 48))); // 48 pts * 5s = 4 min
  const hist = series(now, 5_000, vals);
  const grillTemp = vals[vals.length - 1];
  const v = classifyThermal({ now, hist, setTemp: 250, grillTemp, atTemp: true, noPellets: false, doorActive: false });
  check('pellet: sustained decline flags pellet', v.pellet === true);
  check('pellet: gentle slope not flagged as door', v.door === false);
}

// --- suppression: not up to temp yet (warm-up) -----------------------------
{
  const hist = series(now, 5_000, [120, 130, 140, 150, 160, 170, 180, 190, 200]); // rising warm-up
  const v = classifyThermal({ now, hist, setTemp: 250, grillTemp: 200, atTemp: false, noPellets: false, doorActive: false });
  check('warmup: no door when not atTemp', v.door === false);
  check('warmup: no pellet when not atTemp', v.pellet === false);
}

// --- suppression: controller already flags noPellets -----------------------
{
  const vals = [];
  for (let i = 0; i <= 48; i++) vals.push(Math.round(250 - i * (45 / 48)));
  const hist = series(now, 5_000, vals);
  const v = classifyThermal({ now, hist, setTemp: 250, grillTemp: vals[vals.length - 1], atTemp: true, noPellets: true, doorActive: false });
  check('noPellets flag: skip our pellet heuristic', v.pellet === false);
}

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
