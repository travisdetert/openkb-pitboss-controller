// Thermal-anomaly detection for a running cook — kept dependency-free (no
// Electron) so it can be unit-tested in isolation (see scripts/test-thermal.mjs).
//
// Two patterns, judged only once the grill has reached its setpoint:
//   - Lid/door open: a steep, sudden temp drop (heat dumped fast). Recovers
//     when the lid closes.
//   - Out of pellets: a slow, sustained decline well below the setpoint that
//     doesn't recover — the fire is starving. Caught before the controller's
//     own noPellets flag.
// Thresholds are deliberately conservative and gathered here so they're easy to
// tune from real cooks.

export interface TempPoint {
  t: number;   // epoch ms
  v: number;   // grill temp
}

export interface ThermalThresholds {
  atTempBand: number;     // within this many ° of setpoint counts as "up to temp"
  sampleMs: number;       // min spacing of trend points
  windowMs: number;       // how much history to retain
  doorWindowMs: number;   // short window for the door/lid drop-rate
  doorRate: number;       // °/min fall (or steeper) reads as a lid opening
  doorMinDrop: number;    // …and at least this far below setpoint
  doorRecover: number;    // clear the door latch once within this of setpoint
  pelletWindowMs: number; // long window for the sustained decline
  pelletRate: number;     // °/min sustained fall (or steeper)
  pelletDev: number;      // …while at least this far below setpoint
  pelletRecover: number;  // clear the pellet latch once within this of setpoint
}

export const THERMAL: ThermalThresholds = {
  atTempBand: 15,
  sampleMs: 5_000,
  windowMs: 6 * 60_000,
  doorWindowMs: 60_000,
  doorRate: 25,
  doorMinDrop: 20,
  doorRecover: 10,
  pelletWindowMs: 4 * 60_000,
  pelletRate: 4,
  pelletDev: 40,
  pelletRecover: 20,
};

// Average rate of change (°/min) from the earliest sample within `windowMs` to
// the latest. Returns null until the window holds enough time span to be
// meaningful (half the window), so a cold buffer can't produce a spurious rate.
export function rateOverWindow(
  hist: TempPoint[], now: number, windowMs: number,
): number | null {
  const cutoff = now - windowMs;
  let first: TempPoint | undefined;
  for (const p of hist) { if (p.t >= cutoff) { first = p; break; } }
  const last = hist.length ? hist[hist.length - 1] : undefined;
  if (!first || !last) return null;
  const dtMin = (last.t - first.t) / 60_000;
  if (dtMin < (windowMs / 60_000) * 0.5) return null;
  return (last.v - first.v) / dtMin;
}

export interface ThermalInput {
  now: number;
  hist: TempPoint[];
  setTemp: number;
  grillTemp: number;
  atTemp: boolean;        // has the grill reached its setpoint band this regime?
  noPellets: boolean;     // controller's own flag (don't double-warn)
  doorActive: boolean;    // a door alert is currently latched
  th?: ThermalThresholds;
}

export interface ThermalVerdict {
  door: boolean;
  pellet: boolean;
  dev: number;            // how far below setpoint (° )
  shortRate: number | null;
  longRate: number | null;
}

// Pure classification for the current instant — no latching or side effects.
// The caller owns the latches (fire once, reset on recovery).
export function classifyThermal(inp: ThermalInput): ThermalVerdict {
  const th = inp.th ?? THERMAL;
  const dev = inp.setTemp - inp.grillTemp;
  const shortRate = rateOverWindow(inp.hist, inp.now, th.doorWindowMs);
  const longRate = rateOverWindow(inp.hist, inp.now, th.pelletWindowMs);

  const door = inp.atTemp && dev >= th.doorMinDrop &&
    shortRate != null && shortRate <= -th.doorRate;

  // A sustained, gentler decline — and not the sharp door signature.
  const pellet = inp.atTemp && !inp.noPellets && !(door || inp.doorActive) &&
    dev >= th.pelletDev && longRate != null && longRate <= -th.pelletRate;

  return { door, pellet, dev, shortRate, longRate };
}
