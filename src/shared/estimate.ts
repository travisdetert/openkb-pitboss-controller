// Estimated time until a probe reaches its target.
//
// A direct port of the iOS `CookEstimate` (ios/PitBossKit/Sources/PitBossKit/
// CookEstimate.swift). Both are driven by the same golden vectors in
// `data/estimate-vectors.json`, so a change to one that isn't made to the other
// is a test failure rather than a quiet divergence — see ADR 0007.
//
// Honest about when it can't say. A naive extrapolation through the **stall** —
// the hours-long plateau where evaporative cooling matches the heat going in —
// produces answers like "41 hours", which is worse than no answer because
// someone might believe it. When the rise is too slow or going the wrong way,
// this returns a reason instead of a number.

import type { Sample } from './protocol';

// Where a long cook is in its arc.
//
// The stall is the defining feature of barbecue timing: somewhere around
// 150–170° evaporative cooling matches the heat going in and the meat sits
// still for one to several hours before climbing again. An estimate that
// doesn't know about it is wrong in both directions — wildly optimistic before
// the stall, and absurd during it.
export type Phase =
  | 'beforeStall'   // climbing, with the stall still ahead
  | 'inStall'       // flat in the stall band
  | 'afterStall'    // climbing again, past the plateau — the reliable phase
  | 'noStall';      // not a cut that stalls (poultry, steak, below ~190°)

// Time added to a raw extrapolation for something the rate can't see.
//
// Declared rather than folded in silently: an estimate that quietly includes
// two and a half hours of padding is not the same claim as one that doesn't,
// and the cook should be able to tell which they're reading.
export type Allowance =
  | { type: 'stall'; seconds: number }
  | { type: 'pelletOutage'; count: number; seconds: number };

export function allowanceLabel(a: Allowance): string {
  if (a.type === 'stall') return '~1½h for the stall';
  return a.count === 1
    ? '~1h for the pellet outage'
    : `~${a.count}h for ${a.count} pellet outages`;
}

export type Verdict =
  | { kind: 'eta'; seconds: number; ratePerHour: number; phase: Phase; allowances: Allowance[] }
  | { kind: 'alreadyThere' }
  | { kind: 'stalled'; sinceSeconds: number }   // carries how long it has been flat
  | { kind: 'tooEarly' }                        // not enough history yet
  | { kind: 'noTarget' };

// The band where the stall happens.
export const STALL_BAND = { lower: 150, upper: 175 };

// Only cuts taken well past doneness stall — a 165° chicken never does.
export const STALLING_TARGET_FLOOR = 190;

// Typical stall length, added to an estimate made before one. 90 minutes is a
// middling figure for an unwrapped brisket or butt; they range from under an
// hour to over three. It is declared in the result so the UI can say the
// allowance is included rather than implying precision the number lacks.
export const STALL_ALLOWANCE = 90 * 60;

// What one pellet outage costs: roughly an hour. The fire goes out, the meat
// coasts down, and once the hopper is refilled the grill has to relight and
// climb back before the meat starts moving again. The measured rate can't see
// this — by the time the probe is rising again the loss is already behind it —
// so it's added explicitly for outages recent enough to still be costing time.
export const PELLET_OUTAGE_ALLOWANCE = 60 * 60;

// How recently an outage still counts against the remaining time. Older ones
// are already reflected in the temperature the probe has reached.
export const OUTAGE_RELEVANCE_WINDOW = 2 * 3600;

// How much recent history to derive the rate from. 45 minutes, deliberately
// long: meat climbs a few degrees an hour, so a short window is mostly sensor
// noise and would swing the estimate wildly.
export const WINDOW = 45 * 60;

// Below this rate the answer is "stalled", not a very large number.
export const MINIMUM_RATE_PER_HOUR = 1.5;

// A cook event, as written to the JSONL record. Only `out-of-pellets` affects
// the estimate; the others are carried so callers can pass the whole list.
export interface EstimateEvent {
  at: number;    // epoch ms
  kind: string;
}

function probeValue(sample: Sample, probe: number): number | null {
  const v = (sample as unknown as Record<string, unknown>)[`p${probe}Temp`];
  return typeof v === 'number' ? v : null;
}

export function estimate(
  samples: Sample[],
  probe: number,
  target: number | null | undefined,
  events: EstimateEvent[] = [],
  now: number = Date.now(),
): Verdict {
  if (target === null || target === undefined) return { kind: 'noTarget' };

  const points: Array<[number, number]> = [];
  for (const s of samples) {
    const v = probeValue(s, probe);
    if (v !== null) points.push([s.t, v]);
  }
  const latest = points[points.length - 1];
  if (!latest) return { kind: 'tooEarly' };
  if (latest[1] >= target) return { kind: 'alreadyThere' };

  const cutoff = now - WINDOW * 1000;
  const first = points.find((p) => p[0] >= cutoff);
  if (!first) return { kind: 'tooEarly' };
  const span = (latest[0] - first[0]) / 1000;
  // Need at least half the window, or the rate is guesswork.
  if (span < WINDOW / 2) return { kind: 'tooEarly' };

  const ratePerHour = (latest[1] - first[1]) / (span / 3600);
  const current = latest[1];
  const stalls = target >= STALLING_TARGET_FLOOR;

  // Flat, in the band, on a cut that stalls: say so, and say how long it has
  // been flat — "stalled for 40 minutes" is information, a number extrapolated
  // from a zero rate is not.
  if (ratePerHour < MINIMUM_RATE_PER_HOUR) {
    const inBand = current >= STALL_BAND.lower && current <= STALL_BAND.upper;
    if (!stalls || !inBand) return { kind: 'stalled', sinceSeconds: 0 };
    let flatSince = latest[0];
    for (let i = points.length - 1; i >= 0; i--) {
      if (Math.abs(points[i][1] - current) <= 2) flatSince = points[i][0];
      else break;
    }
    return { kind: 'stalled', sinceSeconds: (latest[0] - flatSince) / 1000 };
  }

  const naive = ((target - current) / ratePerHour) * 3600;

  // A recent outage costs time the rate can't account for.
  const allowances: Allowance[] = [];
  const recentOutages = events.filter(
    (e) => e.kind === 'out-of-pellets' && (now - e.at) / 1000 <= OUTAGE_RELEVANCE_WINDOW
      && now >= e.at,
  ).length;
  if (recentOutages > 0) {
    allowances.push({
      type: 'pelletOutage',
      count: recentOutages,
      seconds: recentOutages * PELLET_OUTAGE_ALLOWANCE,
    });
  }

  let phase: Phase;
  if (!stalls) {
    phase = 'noStall';
  } else if (current < STALL_BAND.lower) {
    // The stall is still ahead, so a straight extrapolation is too optimistic
    // by roughly the length of one.
    phase = 'beforeStall';
    allowances.push({ type: 'stall', seconds: STALL_ALLOWANCE });
  } else if (current <= STALL_BAND.upper) {
    // Climbing inside the band — it may be pushing through, but the stall could
    // still bite, so keep part of the allowance.
    phase = 'inStall';
    allowances.push({ type: 'stall', seconds: STALL_ALLOWANCE / 2 });
  } else {
    phase = 'afterStall';
  }

  const padding = allowances.reduce((sum, a) => sum + a.seconds, 0);
  return { kind: 'eta', seconds: naive + padding, ratePerHour, phase, allowances };
}

// "~2h 40m", or null when there is no estimate to render.
export function estimateLabel(v: Verdict): string | null {
  if (v.kind !== 'eta') return null;
  const total = Math.trunc(v.seconds);
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60);
  if (h >= 1) return m > 0 ? `~${h}h ${m}m` : `~${h}h`;
  return `~${Math.max(1, m)}m`;
}

// The finish time, for "ready around 4:20 PM".
export function finishTime(v: Verdict, now: number = Date.now()): number | null {
  return v.kind === 'eta' ? now + v.seconds * 1000 : null;
}

// A short reason when there's no number, so the UI never just goes blank.
export function explanation(v: Verdict): string | null {
  switch (v.kind) {
    case 'eta':
      if (v.allowances.length === 0) return null;
      return 'includes ' + v.allowances.map(allowanceLabel).join(' and ');
    case 'alreadyThere':
      return 'at target';
    case 'stalled': {
      const minutes = Math.floor(v.sinceSeconds / 60);
      return minutes >= 10
        ? `stalled ${minutes}m — normal, it can last hours`
        : 'stalled — this can last one to three hours';
    }
    case 'tooEarly':
      return 'estimate in ~25m';
    case 'noTarget':
      return null;
  }
}
