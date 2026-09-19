// Generates a SYNTHETIC cook file for inspecting and capturing the UI.
//
// This is NOT recorded grill data. It exists so the dashboard can be rendered
// without standing next to a lit grill, and it is written in the real cook
// format so it exercises the real parsing path (see ios/PitBossKit/.../Replay.swift).
// Anything published as documentation of real behaviour should come from an
// actual recorded cook, not from here.
//
//   node ios/Tools/make-fixture-cook.mjs /tmp/fixture-cook.jsonl
import { writeFileSync } from 'node:fs';

const out = process.argv[2] ?? '/tmp/fixture-cook.jsonl';
const start = Date.UTC(2026, 8, 18, 14, 0, 0);
const STEP = 5_000;               // the recorder's sample interval
const SETPOINT = 250;

const lines = [JSON.stringify({ type: 'meta', startedAt: start, device: 'PBL-F4CFA2B1F294' })];

let grill = 72;                   // ambient start
let probe1 = 68;                  // brisket
let probe2 = 70;                  // ambient probe
const TOTAL = 360;                // 30 minutes at 5s

for (let i = 0; i < TOTAL; i++) {
  const t = start + i * STEP;
  // Warm-up ramp, then hold around the setpoint with the usual pellet-cycle swing.
  if (grill < SETPOINT - 5) grill += 3.4 + Math.random() * 0.8;
  else grill += Math.sin(i / 7) * 3.2 + (Math.random() - 0.5) * 1.6;
  grill = Math.min(grill, SETPOINT + 14);

  // Meat climbs slowly and stalls, as it actually does.
  const climb = probe1 < 150 ? 0.09 : probe1 < 165 ? 0.012 : 0.05;
  probe1 += climb + Math.random() * 0.01;
  probe2 += (Math.random() - 0.5) * 0.3;

  // Auger pulses to feed; igniter only during start-up; fan runs throughout.
  const auger = i < 12 ? true : i % 9 < 2;
  const igniter = i < 30;

  lines.push(JSON.stringify({
    t,
    grillTemp: Math.round(grill),
    grillSetTemp: SETPOINT,
    p1Temp: Math.round(probe1),
    p2Temp: Math.round(probe2),
    p3Temp: null,
    p4Temp: null,
    auger, fan: true, igniter,
  }));
}
lines.push(JSON.stringify({ type: 'end', endedAt: start + TOTAL * STEP }));
writeFileSync(out, lines.join('\n') + '\n', 'utf8');
console.log(`wrote ${out} — ${TOTAL} samples (synthetic fixture, not recorded data)`);
