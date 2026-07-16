// Graceful-shutdown decision logic — kept dependency-free (no Electron) so it
// can be unit-tested (see scripts/test-shutdown.mjs).
//
// Why this matters: shutting a hot pellet grill straight off can let the fire
// smoulder back up the auger toward the hopper — a burnback / hopper fire. The
// safe procedure is to bring the grill down to ~200°F first, THEN power off so
// the controller's fan cool-down can fully extinguish the firepot. This module
// encodes that as a small state machine; main.ts executes the actions and the
// recorder's power-off detection reports completion.

export type ShutdownPhase = 'cooling' | 'finishing' | null;

export interface ShutdownInput {
  moduleIsOn: boolean;
  grillTemp: number | null;
  grillSetTemp: number | null;
  fanState: boolean;
}

export interface ShutdownStep {
  phase: ShutdownPhase;
  action: 'cool' | 'off' | null;              // command main should send
  notice: { title: string; body: string } | null;
}

export interface ShutdownConfig {
  coolAbove: number;   // above this, ramp down before powering off
  coolTarget: number;  // ramp-down setpoint
  coolDoneAt: number;  // once at/below this, proceed to power off
  stallMs: number;
}

export const SHUTDOWN: ShutdownConfig = {
  coolAbove: 250,
  coolTarget: 200,
  coolDoneAt: 210,
  stallMs: 30 * 60_000,
};

// Decide the first step when the user asks to shut down.
export function beginShutdown(inp: ShutdownInput, cfg: ShutdownConfig = SHUTDOWN): ShutdownStep {
  if (inp.moduleIsOn && typeof inp.grillTemp === 'number' && inp.grillTemp > cfg.coolAbove) {
    return {
      phase: 'cooling', action: 'cool',
      notice: {
        title: 'Cooling down before shutdown',
        body: `Bringing the grill from ${inp.grillTemp}° to ${cfg.coolTarget}° first — this prevents a hopper flare-up.`,
      },
    };
  }
  return {
    phase: 'finishing', action: 'off',
    notice: { title: 'Shutting down', body: 'Turning the grill off; the fan will run until the firepot cools.' },
  };
}

// Advance the machine on each fresh grill state.
export function advanceShutdown(phase: ShutdownPhase, inp: ShutdownInput, cfg: ShutdownConfig = SHUTDOWN): ShutdownStep {
  if (phase === 'cooling') {
    if (typeof inp.grillTemp === 'number' && inp.grillTemp <= cfg.coolDoneAt) {
      return {
        phase: 'finishing', action: 'off',
        notice: {
          title: 'Cooled — shutting down',
          body: 'The grill is down to temp; turning it off. The fan will run until the firepot cools.',
        },
      };
    }
    return { phase: 'cooling', action: null, notice: null };
  }
  if (phase === 'finishing') {
    // Fully off (module off AND cool-down fan stopped) — done. The recorder
    // announces the power-off, so we stay quiet here.
    if (!inp.moduleIsOn && !inp.fanState) return { phase: null, action: null, notice: null };
    return { phase: 'finishing', action: null, notice: null };
  }
  return { phase: null, action: null, notice: null };
}

// Cooling progress as a 0..1 fraction, from the temp cooling started at.
export function coolProgress(coolFrom: number, current: number): number {
  const span = coolFrom - SHUTDOWN.coolTarget;
  if (span <= 0) return 1;
  return Math.max(0, Math.min(1, (coolFrom - current) / span));
}
