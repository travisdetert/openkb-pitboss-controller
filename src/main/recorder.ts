// Cook recorder + alerting. Lives in the main process because it's the one
// place that sees every state event centrally and can raise native OS
// notifications (so you can walk away from a long smoke).
//
// Responsibilities:
//   - Detect when a cook starts/ends (grill module powering on/off) and record
//     a throttled temperature history to a per-cook JSONL file in userData.
//   - Watch state transitions and fire edge-triggered notifications: a probe
//     reaching its target, running out of pellets, or a controller error.
//
// Probe/grill targets come from the SettingsStore, which the renderer keeps in
// sync as the user adjusts them — so we always compare against the live target.

import { app } from 'electron';
import * as fs from 'fs';
import * as path from 'path';
import { CookMeta, GrillState, MaintenanceState, NoticeLevel, Sample } from '../shared/protocol';
import { SettingsStore } from './store';
import { classifyThermal, TempPoint, THERMAL, ThermalThresholds } from './thermal';
import { freshMaintenance, isFlareup, maintenanceDue, maintenanceReasons, MaintenanceThresholds } from './maintenance';
import { resolveConfig } from './config';
import { log } from './log';

const SAMPLE_INTERVAL_MS = 5_000;   // at most one recorded point per 5s
const PROBE_COUNT = 4;
const OVER_TARGET_MARGIN = 5;       // ° past target before we flag "over"

function fileStem(epochMs: number): string {
  // 2026-06-23T18:30:00.000Z -> 2026-06-23T18-30-00  (filename-safe, sortable)
  return new Date(epochMs).toISOString().replace(/:/g, '-').replace(/\..+$/, '');
}

// A cook id is always a fileStem() timestamp. readCook(id) is reachable over IPC,
// so validate the shape before building a path — never let an id like "../x" out
// of the userData dir (defense in depth; the renderer only ever passes real stems).
const COOK_ID_RE = /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$/;
function isValidCookId(id: string): boolean {
  return typeof id === 'string' && COOK_ID_RE.test(id);
}

function probeTemp(state: GrillState, i: number): number | null {
  const v = (state as Record<string, unknown>)[`p${i}Temp`];
  return typeof v === 'number' ? v : null;
}

export class Recorder {
  private readonly dir: string;
  private prev: GrillState = {};
  private device?: string;

  // Active-cook bookkeeping.
  private cookId: string | null = null;
  private cookStartedAt = 0;
  private lastSampleAt = 0;
  private samples: Sample[] = [];        // in-memory copy of the active cook
  private stream: fs.WriteStream | null = null;

  // Alert latches — reset when the underlying condition clears, so each fresh
  // occurrence notifies exactly once.
  private probeFired: Record<number, boolean> = {};
  private probeOverFired: Record<number, boolean> = {};
  private pelletsFired = false;
  private errorFired = false;

  // Power-off / session-concluded tracking: fires once the grill has fully shut
  // down (module off AND the cool-down fan has stopped) after having run.
  private wasRunning = false;
  private poweredOffFired = false;

  // Maintenance tracking (cooks / run-time / flare-ups since last clean).
  private maint: MaintenanceState = freshMaintenance();
  private lastObserveAt = 0;
  private lastMaintSaveAt = 0;
  private flareupFired = false;
  private cleaningDueFired = false;
  // Suppress flare-up detection while a commanded setpoint drop (shutdown, or the
  // user lowering it) means the temp is legitimately above the new lower setpoint.
  private flareLastSet: number | null = null;
  private flareSuppressed = false;
  onMaintenance?: (state: MaintenanceState, due: boolean, reasons: string[]) => void;

  // Thermal-anomaly detection (see thermal.ts): a rolling temp buffer plus
  // per-condition latches so each event notifies once until it recovers.
  private tempHist: TempPoint[] = [];
  private lastThermalAt = 0;
  private lastSetTemp: number | null = null;
  private atTemp = false;        // reached the setpoint band since it last changed
  private doorFired = false;
  private pelletLowFired = false;

  // Component-activity latches — OR'd between 5s samples so brief auger pulses
  // still register on the activity graph.
  private augerSeen = false;
  private fanSeen = false;
  private igniterSeen = false;

  constructor(private readonly store: SettingsStore) {
    this.dir = path.join(app.getPath('userData'), 'cooks');
    try {
      fs.mkdirSync(this.dir, { recursive: true });
    } catch (e) {
      log('cooks dir create failed:', (e as Error).message);
    }
    this.maint = { ...freshMaintenance(), ...(this.store.get().maintenance ?? {}) };
    this.cleaningDueFired = maintenanceDue(this.maint);
  }

  setDevice(name?: string): void {
    if (name) this.device = name;
  }

  /** Called for every state event from the sidecar. */
  observe(state: GrillState): void {
    const now = Date.now();
    // Latch component activity for the activity graph before we (maybe) sample.
    if (state.motorState) this.augerSeen = true;
    if (state.fanState) this.fanSeen = true;
    if (state.hotState) this.igniterSeen = true;

    const cfg = resolveConfig(this.store.get());
    this.handleCookLifecycle(state, now);
    if (this.cookId) this.maybeSample(state, now);
    this.checkAlerts(state);
    this.checkThermal(state, now, cfg.thermal);
    this.checkPowerState(state);
    this.checkMaintenance(state, now, cfg.maintenance);
    this.logTransitions(state);
    this.prev = { ...this.prev, ...state };
  }

  // --- maintenance ---------------------------------------------------------

  // Accumulate run-time, count flare-ups (possible grease fires), and nudge the
  // user to clean once usage or flare-ups cross a threshold.
  private checkMaintenance(state: GrillState, now: number, mt: MaintenanceThresholds): void {
    // Integrate grill-on time.
    if (this.lastObserveAt && state.moduleIsOn) {
      this.maint.runSecondsSinceClean += Math.min(now - this.lastObserveAt, 10_000) / 1000;
    }
    this.lastObserveAt = now;

    const t = typeof state.grillTemp === 'number' ? state.grillTemp : null;
    const set = typeof state.grillSetTemp === 'number' ? state.grillSetTemp : null;

    // A commanded setpoint *drop* (shutdown cool-down, or the user lowering it)
    // leaves the temp legitimately above the new setpoint — not a flare-up.
    // Suppress until the temp settles back near the (lower) setpoint.
    if (set != null) {
      if (this.flareLastSet != null && set < this.flareLastSet) this.flareSuppressed = true;
      this.flareLastSet = set;
    }
    if (this.flareSuppressed && t != null && set != null && t <= set + 25) {
      this.flareSuppressed = false;
    }

    // Flare-up: temp spikes well above setpoint while running (possible grease
    // fire). Edge-triggered; re-arms once temp settles back toward the setpoint.
    const flaring = !this.flareSuppressed && isFlareup(t, set, !!state.moduleIsOn, mt);
    if (flaring) {
      if (!this.flareupFired) {
        this.flareupFired = true;
        this.maint.flareupsSinceClean += 1;
        this.notify('Large temperature flare-up',
          `Grill hit ${state.grillTemp}° (set ${state.grillSetTemp}°) — possible grease fire. Keep an eye on it and clean the grease tray/bucket soon.`, true);
        this.emitMaintenance();
      }
    } else if (t != null && set != null && t < set + 50) {
      this.flareupFired = false;
    }

    // Recommend a clean once due (once, until reset via "Cleaned").
    if (maintenanceDue(this.maint, mt)) {
      if (!this.cleaningDueFired) {
        this.cleaningDueFired = true;
        this.notify('Time to clean the grill',
          `Recommended after ${maintenanceReasons(this.maint, mt).join(' · ')} since the last clean.`);
        this.emitMaintenance();
      }
    }

    // Persist + relay periodically (run-time ticks constantly).
    if (now - this.lastMaintSaveAt > 30_000) {
      this.lastMaintSaveAt = now;
      this.persistMaintenance();
      this.emitMaintenance();
    }
  }

  private emitMaintenance(): void {
    const mt = resolveConfig(this.store.get()).maintenance;
    this.onMaintenance?.(this.maint, maintenanceDue(this.maint, mt), maintenanceReasons(this.maint, mt));
  }

  private persistMaintenance(): void {
    this.store.set({ maintenance: this.maint });
  }

  /** Reset the maintenance counters — the user has cleaned the grill. */
  resetMaintenance(): void {
    this.maint = { ...freshMaintenance(), cleanedAt: Date.now() };
    this.flareupFired = false;
    this.cleaningDueFired = false;
    this.persistMaintenance();
    this.emitMaintenance();
    log('maintenance reset (grill cleaned)');
  }

  /** Current maintenance snapshot, for the initial renderer sync. */
  maintenance(): MaintenanceState {
    return this.maint;
  }

  // --- cook lifecycle ------------------------------------------------------

  private handleCookLifecycle(state: GrillState, now: number): void {
    const on = !!state.moduleIsOn;
    const prevOn = this.prev.moduleIsOn;   // boolean | undefined (undefined = first sync)
    if (on && !this.cookId) {
      this.startCook(now);
      // Announce a genuine off->on power-up, not the initial state on launch.
      if (prevOn === false) {
        this.notify('Grill started', 'Your grill is powering up. 🔥');
      }
    } else if (!on && prevOn && this.cookId) {
      this.endCook(now);
    }
  }

  private startCook(now: number): void {
    this.cookId = fileStem(now);
    this.cookStartedAt = now;
    this.lastSampleAt = 0;
    this.samples = [];
    const file = path.join(this.dir, `${this.cookId}.jsonl`);
    this.stream = fs.createWriteStream(file, { flags: 'a' });
    // Snapshot the probe labels at cook start so a past session shows what was
    // on each probe even after they're renamed for the next cook.
    this.writeLine({
      type: 'meta', startedAt: now, device: this.device,
      labels: this.store.get().probeLabels,
    });
    log(`cook started: ${this.cookId}`);
  }

  private endCook(now: number): void {
    if (!this.cookId) return;
    this.writeLine({ type: 'end', endedAt: now });
    this.stream?.end();
    this.stream = null;
    log(`cook ended: ${this.cookId} (${this.samples.length} samples)`);
    this.cookId = null;
    // Count the completed cook toward the cleaning cadence.
    this.maint.cooksSinceClean += 1;
    this.persistMaintenance();
    this.emitMaintenance();
  }

  private maybeSample(state: GrillState, now: number): void {
    if (now - this.lastSampleAt < SAMPLE_INTERVAL_MS) return;
    this.lastSampleAt = now;
    const s = this.prev; // merged-so-far view + this update
    const merged = { ...s, ...state };
    const sample: Sample = {
      t: now,
      grillTemp: merged.grillTemp ?? null,
      grillSetTemp: merged.grillSetTemp ?? null,
      p1Temp: probeTemp(merged, 1),
      p2Temp: probeTemp(merged, 2),
      p3Temp: probeTemp(merged, 3),
      p4Temp: probeTemp(merged, 4),
      auger: this.augerSeen || !!merged.motorState,
      fan: this.fanSeen || !!merged.fanState,
      igniter: this.igniterSeen || !!merged.hotState,
    };
    this.augerSeen = this.fanSeen = this.igniterSeen = false;
    this.samples.push(sample);
    this.writeLine(sample);
  }

  private writeLine(obj: object): void {
    try {
      this.stream?.write(JSON.stringify(obj) + '\n');
    } catch (e) {
      log('cook write failed:', (e as Error).message);
    }
  }

  // Log component on/off edges so the unified log answers "did it actually
  // engage?" — primer motor especially, since the grill may accept a prime
  // command yet not run the motor while a cook is active.
  private logTransitions(state: GrillState): void {
    const keys: (keyof GrillState)[] = ['primeState', 'motorState', 'fanState', 'hotState'];
    for (const k of keys) {
      const cur = state[k];
      if (cur === undefined) continue;
      if (!!cur !== !!this.prev[k]) log(`${k} -> ${cur ? 'on' : 'off'}`);
    }
  }

  // --- alerts --------------------------------------------------------------

  private checkAlerts(state: GrillState): void {
    const settings = this.store.get();
    const userTargets = settings.probeTargets;
    const labels = settings.probeLabels || {};
    for (let i = 1; i <= PROBE_COUNT; i++) {
      const cur = probeTemp(state, i);
      // Key off the target the user manages in the app (setting it also pushes it
      // to the grill). Clearing it here stops the warning — the grill's own copy
      // is not preferred, so a cleared target doesn't linger.
      const target = userTargets[i];
      if (cur == null || !target) continue;
      const name = labels[i]?.trim() || `Probe ${i}`;
      if (cur >= target) {
        if (!this.probeFired[i]) {
          this.probeFired[i] = true;
          this.notify(`${name} reached target`, `${cur}° — target was ${target}°`, true);
        }
      } else if (cur < target - 2) {
        this.probeFired[i] = false; // hysteresis so it can fire again next cook
      }
      // Escalate when it climbs well past the target — the food is overcooking.
      if (cur >= target + OVER_TARGET_MARGIN) {
        if (!this.probeOverFired[i]) {
          this.probeOverFired[i] = true;
          this.notify(`${name} over target`, `${cur}° — ${cur - target}° over the ${target}° target.`, true);
        }
      } else if (cur < target) {
        this.probeOverFired[i] = false;
      }
    }

    this.edge('noPellets', !!state.noPellets, 'pelletsFired',
      'Out of pellets', 'The hopper is empty — refill to keep the fire going.');

    const hasError = !!(state.highTempErr || state.fanErr || state.hotErr ||
      state.motorErr || state.err1 || state.err2 || state.err3 || state.erL);
    this.edge('error', hasError, 'errorFired',
      'Grill error', this.describeErrors(state));
  }

  private edge(
    _key: string, active: boolean,
    latch: 'pelletsFired' | 'errorFired',
    title: string, body: string,
  ): void {
    if (active && !this[latch]) {
      this[latch] = true;
      this.notify(title, body);
    } else if (!active) {
      this[latch] = false;
    }
  }

  // Watch the grill-temp trend for a lid opening (steep drop) or a starving
  // fire / out-of-pellets (slow sustained decline below setpoint). Only judged
  // once the grill has reached temp, so warm-up and setpoint changes don't
  // false-alarm. See thermal.ts for the thresholds and rationale.
  private checkThermal(state: GrillState, now: number, th: ThermalThresholds): void {
    const on = !!state.moduleIsOn;
    const set = typeof state.grillSetTemp === 'number' ? state.grillSetTemp : null;
    const temp = typeof state.grillTemp === 'number' ? state.grillTemp : null;

    // Off or data missing: reset the whole detector.
    if (!on || set == null || temp == null) {
      this.tempHist = [];
      this.atTemp = false;
      this.doorFired = this.pelletLowFired = false;
      this.lastSetTemp = set;
      return;
    }

    // A setpoint change starts a fresh regime — require re-reaching temp before
    // warning again (this also suppresses the natural drop after lowering it).
    if (set !== this.lastSetTemp) {
      this.lastSetTemp = set;
      this.atTemp = false;
      this.doorFired = this.pelletLowFired = false;
      this.tempHist = [];
    }
    if (temp >= set - th.atTempBand) this.atTemp = true;

    // Feed the trend buffer (throttled) and prune to the retention window.
    if (now - this.lastThermalAt >= th.sampleMs) {
      this.lastThermalAt = now;
      this.tempHist.push({ t: now, v: temp });
      const cutoff = now - th.windowMs;
      while (this.tempHist.length && this.tempHist[0].t < cutoff) this.tempHist.shift();
    }

    const v = classifyThermal({
      now, hist: this.tempHist, setTemp: set, grillTemp: temp,
      atTemp: this.atTemp, noPellets: !!state.noPellets, doorActive: this.doorFired, th,
    });

    // Lid/door open — steep drop. Latch until temp recovers toward setpoint.
    if (v.door) {
      if (!this.doorFired) {
        this.doorFired = true;
        this.notify('Lid open?',
          `Grill temp is dropping fast (${Math.round(v.shortRate ?? 0)}°/min, now ${temp}°). Close the lid to hold heat.`);
      }
    } else if (v.dev < th.doorRecover) {
      this.doorFired = false;
    }

    // Starving fire / out of pellets — slow sustained decline. Latch similarly.
    if (v.pellet) {
      if (!this.pelletLowFired) {
        this.pelletLowFired = true;
        this.notify('Running low on pellets?',
          `Temp has fallen to ${temp}° (set ${set}°) and keeps dropping — check the hopper and firepot.`);
      }
    } else if (v.dev < th.pelletRecover) {
      this.pelletLowFired = false;
    }
  }

  // Announce a full power-off once, when the grill has run and then completely
  // shut down — module off AND the cool-down fan stopped. This is the safe,
  // "session concluded" moment (and the completion signal a graceful shutdown
  // waits on). Re-arms when the grill next powers on.
  private checkPowerState(state: GrillState): void {
    if (state.moduleIsOn) {
      this.wasRunning = true;
      this.poweredOffFired = false;
      return;
    }
    // Module off. Wait for the fan to stop (cool-down complete) before calling it.
    if (this.wasRunning && state.fanState === false && !this.poweredOffFired) {
      this.poweredOffFired = true;
      this.wasRunning = false;
      this.notify('Your Pit Boss is powered off',
        'Shutdown complete — the grill is cool and this cook session is concluded.');
    }
  }


  private describeErrors(state: GrillState): string {
    const errs: string[] = [];
    if (state.highTempErr) errs.push('high temp');
    if (state.fanErr) errs.push('fan');
    if (state.hotErr) errs.push('igniter');
    if (state.motorErr) errs.push('auger');
    if (state.err1 || state.err2 || state.err3 || state.erL) errs.push('controller');
    return errs.length ? `Fault: ${errs.join(', ')}.` : 'Controller reported a fault.';
  }

  // Set by main to relay notifications to the renderer's status bar.
  onNotice?: (title: string, body: string, level: NoticeLevel) => void;

  // Hand off to main (via onNotice), which owns the single enriched
  // OS-notification path (click-to-focus, sound + persistence for alerts, dock
  // bounce) and logging. The recorder no longer creates notifications itself.
  private notify(title: string, body: string, beep = false): void {
    this.onNotice?.(title, body, beep ? 'alert' : 'warn');
  }

  // --- queries (for IPC) ---------------------------------------------------

  /** Samples for the active cook, or the most recent one if idle. */
  history(): Sample[] {
    if (this.cookId) return this.samples;
    const latest = this.listCooks()[0];
    return latest ? this.readCook(latest.id) : [];
  }

  listCooks(): CookMeta[] {
    let files: string[];
    try {
      files = fs.readdirSync(this.dir).filter((f) => f.endsWith('.jsonl'));
    } catch {
      return [];
    }
    const metas = files.map((f) => this.metaFor(f)).filter((m): m is CookMeta => !!m);
    metas.sort((a, b) => b.startedAt - a.startedAt); // newest first
    return metas;
  }

  readCook(id: string): Sample[] {
    if (!isValidCookId(id)) return [];
    const file = path.join(this.dir, `${id}.jsonl`);
    let raw: string;
    try {
      raw = fs.readFileSync(file, 'utf8');
    } catch {
      return [];
    }
    const out: Sample[] = [];
    for (const line of raw.split('\n')) {
      if (!line.trim()) continue;
      try {
        const obj = JSON.parse(line);
        if (typeof obj.t === 'number') out.push(obj as Sample);
      } catch { /* skip malformed line */ }
    }
    return out;
  }

  private metaFor(filename: string): CookMeta | null {
    const id = filename.replace(/\.jsonl$/, '');
    const file = path.join(this.dir, filename);
    let raw: string;
    try {
      raw = fs.readFileSync(file, 'utf8');
    } catch {
      return null;
    }
    let startedAt = 0;
    let endedAt: number | null = null;
    let device: string | undefined;
    let labels: Record<number, string> | undefined;
    let samples = 0;
    for (const line of raw.split('\n')) {
      if (!line.trim()) continue;
      try {
        const obj = JSON.parse(line);
        if (obj.type === 'meta') { startedAt = obj.startedAt; device = obj.device; labels = obj.labels; }
        else if (obj.type === 'end') endedAt = obj.endedAt;
        else if (typeof obj.t === 'number') samples++;
      } catch { /* skip */ }
    }
    if (!startedAt) return null;
    return { id, startedAt, endedAt, samples, device, labels };
  }

  dispose(): void {
    if (this.cookId) this.endCook(Date.now());
  }
}
