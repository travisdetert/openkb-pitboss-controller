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

import { app, Notification, shell } from 'electron';
import * as fs from 'fs';
import * as path from 'path';
import { CookMeta, GrillState, Sample } from '../shared/protocol';
import { SettingsStore } from './store';
import { log } from './log';

const SAMPLE_INTERVAL_MS = 5_000;   // at most one recorded point per 5s
const PROBE_COUNT = 4;

function fileStem(epochMs: number): string {
  // 2026-06-23T18:30:00.000Z -> 2026-06-23T18-30-00  (filename-safe, sortable)
  return new Date(epochMs).toISOString().replace(/:/g, '-').replace(/\..+$/, '');
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
  private pelletsFired = false;
  private errorFired = false;

  constructor(private readonly store: SettingsStore) {
    this.dir = path.join(app.getPath('userData'), 'cooks');
    try {
      fs.mkdirSync(this.dir, { recursive: true });
    } catch (e) {
      log('cooks dir create failed:', (e as Error).message);
    }
  }

  setDevice(name?: string): void {
    if (name) this.device = name;
  }

  /** Called for every state event from the sidecar. */
  observe(state: GrillState): void {
    const now = Date.now();
    this.handleCookLifecycle(state, now);
    if (this.cookId) this.maybeSample(state, now);
    this.checkAlerts(state);
    this.logTransitions(state);
    this.prev = { ...this.prev, ...state };
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
    this.writeLine({ type: 'meta', startedAt: now, device: this.device });
    log(`cook started: ${this.cookId}`);
  }

  private endCook(now: number): void {
    if (!this.cookId) return;
    this.writeLine({ type: 'end', endedAt: now });
    this.stream?.end();
    this.stream = null;
    log(`cook ended: ${this.cookId} (${this.samples.length} samples)`);
    this.cookId = null;
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
    };
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
    const userTargets = this.store.get().probeTargets;
    for (let i = 1; i <= PROBE_COUNT; i++) {
      const cur = probeTemp(state, i);
      // Prefer the grill's OWN target (what triggers its "IT" alert) so our
      // notification fires at the same instant; fall back to the user's value.
      const target = this.grillProbeTarget(state, i) ?? userTargets[i];
      if (cur == null || !target) continue;
      if (cur >= target) {
        if (!this.probeFired[i]) {
          this.probeFired[i] = true;
          this.notify(`Probe ${i} reached target`, `${cur}° — target was ${target}°`, true);
        }
      } else if (cur < target - 2) {
        this.probeFired[i] = false; // hysteresis so it can fire again next cook
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

  // The grill reports a target only for probe 1 (p1Target). 960 is pytboss's
  // "unset / unplugged" sentinel; ignore it and implausible values.
  private grillProbeTarget(state: GrillState, i: number): number | null {
    const v = (state as Record<string, unknown>)[`p${i}Target`];
    if (typeof v !== 'number' || v === 960 || v < 50 || v > 600) return null;
    return v;
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

  private notify(title: string, body: string, beep = false): void {
    log(`notify: ${title} — ${body}`);
    // An audible cue for "meat is done", to match the grill's own beep. The
    // OS notification carries the default sound; shell.beep() adds emphasis.
    if (beep) {
      try { shell.beep(); } catch { /* non-fatal */ }
    }
    if (!Notification.isSupported()) return;
    try {
      new Notification({ title, body, silent: !beep }).show();
    } catch (e) {
      log('notification failed:', (e as Error).message);
    }
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
    let samples = 0;
    for (const line of raw.split('\n')) {
      if (!line.trim()) continue;
      try {
        const obj = JSON.parse(line);
        if (obj.type === 'meta') { startedAt = obj.startedAt; device = obj.device; }
        else if (obj.type === 'end') endedAt = obj.endedAt;
        else if (typeof obj.t === 'number') samples++;
      } catch { /* skip */ }
    }
    if (!startedAt) return null;
    return { id, startedAt, endedAt, samples, device };
  }

  dispose(): void {
    if (this.cookId) this.endCook(Date.now());
  }
}
