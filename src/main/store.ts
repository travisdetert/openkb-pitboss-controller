// Tiny JSON settings store persisted in the app's userData directory. Holds the
// things worth remembering across launches: last setpoint, probe targets, the
// grill we connect to, and the window geometry. Writes are debounced so rapid
// updates (e.g. dragging the window) don't thrash the disk.

import { app } from 'electron';
import * as fs from 'fs';
import * as path from 'path';
import { Settings } from '../shared/protocol';
import { log } from './log';

const DEFAULTS: Settings = {
  setpoint: 225,
  probeTargets: { 1: 145, 2: 165 },
  grillName: 'PBL-',
  grillModel: 'PB1100PSC3',
};

export class SettingsStore {
  private readonly file: string;
  private data: Settings;
  private writeTimer: NodeJS.Timeout | null = null;

  constructor() {
    this.file = path.join(app.getPath('userData'), 'settings.json');
    this.data = this.load();
  }

  private fresh(): Settings {
    return { ...DEFAULTS, probeTargets: { ...DEFAULTS.probeTargets } };
  }

  private load(): Settings {
    let raw: string;
    try {
      raw = fs.readFileSync(this.file, 'utf8');
    } catch (e) {
      // A missing file is normal on first run; anything else is worth a note.
      if ((e as NodeJS.ErrnoException).code !== 'ENOENT') {
        log('settings read failed, using defaults:', (e as Error).message);
      }
      return this.fresh();
    }

    // An empty file means a prior write was interrupted (see flush()). Don't
    // silently swallow it — say so, so it's diagnosable instead of mysterious.
    if (!raw.trim()) {
      log('settings file was empty — a prior write was likely interrupted; restoring defaults');
      return this.fresh();
    }

    try {
      const parsed = JSON.parse(raw) as Partial<Settings>;
      // Shallow-merge over defaults so new fields appear without wiping old ones.
      return {
        ...DEFAULTS,
        ...parsed,
        probeTargets: { ...DEFAULTS.probeTargets, ...(parsed.probeTargets || {}) },
      };
    } catch (e) {
      // Preserve the unparseable file (a hand-edit typo, say) instead of
      // overwriting it — losing a user's edit silently is the worse failure.
      try {
        fs.renameSync(this.file, this.file + '.bad');
        log('settings file was corrupt — backed up to settings.json.bad, using defaults:', (e as Error).message);
      } catch {
        log('settings file was corrupt and could not be backed up, using defaults:', (e as Error).message);
      }
      return this.fresh();
    }
  }

  get(): Settings {
    return this.data;
  }

  /** Merge a partial patch, persist (debounced), and return the new settings. */
  set(patch: Partial<Settings>): Settings {
    this.data = {
      ...this.data,
      ...patch,
      probeTargets: { ...this.data.probeTargets, ...(patch.probeTargets || {}) },
    };
    this.scheduleWrite();
    return this.data;
  }

  private scheduleWrite(): void {
    if (this.writeTimer) clearTimeout(this.writeTimer);
    this.writeTimer = setTimeout(() => this.flush(), 400);
  }

  /** Write immediately (also called on quit so nothing is lost). */
  flush(): void {
    if (this.writeTimer) {
      clearTimeout(this.writeTimer);
      this.writeTimer = null;
    }
    // Atomic write: fill a temp file, then rename over the target. writeFileSync
    // truncates first, so a crash mid-write would otherwise leave a 0-byte file
    // that reads back as "no settings". rename() on the same dir is atomic — the
    // real file is never in a half-written state.
    const tmp = this.file + '.tmp';
    try {
      fs.writeFileSync(tmp, JSON.stringify(this.data, null, 2));
      fs.renameSync(tmp, this.file);
    } catch (e) {
      log('settings write failed:', (e as Error).message);
      try { fs.rmSync(tmp, { force: true }); } catch { /* best effort */ }
    }
  }
}
