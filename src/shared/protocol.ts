// Shared types for the sidecar JSON protocol and grill state.
// Kept dependency-free so both main and renderer can import it.

export interface GrillState {
  moduleIsOn?: boolean;
  // error flags
  err1?: boolean;
  err2?: boolean;
  err3?: boolean;
  highTempErr?: boolean;
  fanErr?: boolean;
  hotErr?: boolean;
  motorErr?: boolean;
  noPellets?: boolean;
  erL?: boolean;
  // component states
  fanState?: boolean;
  hotState?: boolean;   // igniter / hot rod
  motorState?: boolean; // auger
  lightState?: boolean;
  primeState?: boolean;
  // recipe
  recipeStep?: number;
  recipeTime?: number;
  // temperatures (Fahrenheit when isFahrenheit)
  p1Target?: number | null;
  p1Temp?: number | null;
  p2Temp?: number | null;
  p3Temp?: number | null;
  p4Temp?: number | null;
  grillSetTemp?: number | null;
  grillTemp?: number | null;
  smokerActTemp?: number | null;
  isFahrenheit?: boolean;
}

export interface Capabilities {
  model: string;
  min_temp: number;
  max_temp: number;
  temp_increments: number[];
  meat_probes: number;
  has_lights: boolean;
}

export interface ConnStatus {
  connected: boolean;
  connecting: boolean;
  reason: string;
  device?: string;
}

export interface ScanDevice {
  name: string;
  rssi: number;
}

// Events pushed from sidecar -> main -> renderer
export type SidecarEvent =
  | { type: 'ready'; model_default: string; name_default: string }
  | { type: 'status'; connected: boolean; connecting: boolean; reason: string; device?: string }
  | { type: 'capabilities'; model: string; min_temp: number; max_temp: number; temp_increments: number[]; meat_probes: number; has_lights: boolean }
  | { type: 'state'; data: GrillState }
  | { type: 'scan_result'; id?: number; devices: ScanDevice[] }
  | { type: 'ack'; id?: number; ok: true; result: unknown }
  | { type: 'error'; id?: number; ok: false; message: string };

// Commands renderer -> main -> sidecar
export type GrillCommand =
  | { cmd: 'connect'; name?: string; model?: string }
  | { cmd: 'disconnect' }
  | { cmd: 'scan'; seconds?: number }
  | { cmd: 'set_temp'; value: number }
  | { cmd: 'set_probe'; probe: number; value: number }
  | { cmd: 'light'; on: boolean }
  | { cmd: 'prime'; on: boolean }
  | { cmd: 'off' }
  | { cmd: 'refresh' }
  | { cmd: 'ping' };

// Persisted user settings (lives in userData/settings.json, owned by main).
export interface Settings {
  setpoint: number;
  probeTargets: Record<number, number>;
  grillName: string;
  grillModel: string;
  windowBounds?: { x?: number; y?: number; width: number; height: number };
}

// One recorded point in a cook's temperature history.
export interface Sample {
  t: number;                    // epoch ms
  grillTemp: number | null;
  grillSetTemp: number | null;
  p1Temp: number | null;
  p2Temp: number | null;
  p3Temp: number | null;
  p4Temp: number | null;
}

// Summary of a saved cook session.
export interface CookMeta {
  id: string;                   // file stem, e.g. '2026-06-23T18-30-00'
  startedAt: number;            // epoch ms
  endedAt: number | null;       // null while still running
  samples: number;              // sample count
  device?: string;
}

// Channel names for IPC between main and renderer.
export const IPC = {
  command: 'pitboss:command',     // renderer -> main (invoke), returns ack result
  event: 'pitboss:event',         // main -> renderer (push: state/status/etc.)
  getSettings: 'pitboss:settings:get',
  setSettings: 'pitboss:settings:set',
  history: 'pitboss:history',      // samples for the active (or latest) cook
  listCooks: 'pitboss:cooks:list',
  readCook: 'pitboss:cooks:read',  // full sample array for one cook id
} as const;
