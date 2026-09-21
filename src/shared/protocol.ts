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

// A supported grill model, for the first-run picker.
export interface ModelInfo {
  name: string;
  control_board: string | null;
  min_temp: number | null;
  max_temp: number | null;
  meat_probes: number;
  has_lights: boolean;
}

// Events pushed from sidecar -> main -> renderer
export type SidecarEvent =
  | { type: 'ready'; model_default: string; name_default: string }
  | { type: 'status'; connected: boolean; connecting: boolean; reason: string; device?: string;
      bt_reason?: BluetoothBlockedReason; bt_message?: string }
  | { type: 'capabilities'; model: string; min_temp: number; max_temp: number; temp_increments: number[]; meat_probes: number; has_lights: boolean }
  | { type: 'state'; data: GrillState }
  | { type: 'scan_result'; id?: number; devices: ScanDevice[] }
  | { type: 'models'; id?: number; control_board?: string | null; models: ModelInfo[] }
  | { type: 'ack'; id?: number; ok: true; result: unknown }
  | { type: 'error'; id?: number; ok: false; message: string }
  // main -> renderer relay of a fired notification, so the in-app status bar can
  // surface it (lid open, probe done, pellets, …) alongside the OS notification.
  | { type: 'notice'; title: string; body: string; level: NoticeLevel }
  // main -> renderer graceful-shutdown progress (null phase = not shutting down).
  | { type: 'shutdown'; phase: 'cooling' | 'finishing' | null; coolFrom: number; coolTarget: number }
  // main -> renderer maintenance counters + whether a cleaning is recommended.
  | { type: 'maintenance'; state: MaintenanceState; due: boolean; reasons: string[] };

export type NoticeLevel = 'info' | 'warn' | 'alert';

// ---- Bluetooth availability -------------------------------------------------
// Why the radio is unusable, when it is. Sent with a `status` whose reason is
// `bluetooth_unavailable`. These come from bleak's structured
// BleakBluetoothNotAvailableReason enum rather than a parsed error string, so a
// library upgrade rewording its messages cannot silently turn a denial back
// into "no grill found" — which is exactly what it used to look like.
export type BluetoothBlockedReason =
  | 'denied'          // the user denied this app at the system prompt
  | 'restricted'      // blocked by policy / parental controls
  | 'denied_unknown'  // unauthorized, cause not reported
  | 'powered_off'     // radio switched off
  | 'no_radio'        // no BLE hardware, or no central role
  | 'unknown';

export interface BluetoothGuidance {
  title: string;
  detail: string;
  /** True when System Settings → Privacy & Security → Bluetooth is the fix. */
  openSettings: boolean;
}

/** What to tell the user, and whether a Settings button would help. */
export function bluetoothGuidance(reason: BluetoothBlockedReason): BluetoothGuidance {
  switch (reason) {
    case 'denied':
    case 'denied_unknown':
      return {
        title: 'Bluetooth permission is turned off',
        detail: 'This app needs Bluetooth to reach your grill — there is no cloud '
          + 'fallback, so nothing works without it. Turn it on for “openkb-pit-boss” '
          + 'in System Settings, and the app reconnects on its own.',
        openSettings: true,
      };
    case 'restricted':
      return {
        title: 'Bluetooth is restricted on this Mac',
        detail: 'A policy or parental-control profile is blocking Bluetooth. '
          + 'An administrator has to lift the restriction.',
        openSettings: true,
      };
    case 'powered_off':
      return {
        title: 'Bluetooth is switched off',
        detail: 'Turn Bluetooth on from Control Centre or System Settings. '
          + 'The app keeps trying and reconnects the moment it comes back.',
        openSettings: false,
      };
    case 'no_radio':
      return {
        title: 'This Mac has no Bluetooth LE radio',
        detail: 'The grill is reachable over Bluetooth Low Energy only, so this '
          + 'machine cannot talk to it.',
        openSettings: false,
      };
    default:
      return {
        title: 'Bluetooth is unavailable',
        detail: 'macOS reported Bluetooth as unavailable without saying why. '
          + 'Check System Settings, and that the radio is on.',
        openSettings: true,
      };
  }
}

// Commands renderer -> main -> sidecar
export type GrillCommand =
  | { cmd: 'connect'; name?: string; model?: string }
  | { cmd: 'disconnect' }
  | { cmd: 'scan'; seconds?: number }
  | { cmd: 'list_models'; control_board?: string | null }
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
  probeLabels?: Record<number, string>;   // user names per probe ("Chicken", …)
  cookNames?: Record<string, string>;      // optional user name/note per cook id
  grillName: string;
  grillModel: string;
  theme?: 'auto' | 'light' | 'dark';   // 'auto' follows the OS; a choice overrides it
  grillConfigured?: boolean;   // true once the user has picked their grill (gates the wizard)
  windowBounds?: { x?: number; y?: number; width: number; height: number };
  pellets?: PelletState;
  maintenance?: MaintenanceState;
  // User-adjustable tuning (see src/main/config.ts for how these resolve to the
  // engine thresholds). All optional — absent means "use the built-in default".
  detectionSensitivity?: DetectionSensitivity;
  maintenanceThresholds?: { afterCooks: number; afterHours: number; afterFlareups: number };
  shutdownConfig?: { coolAbove: number; coolTarget: number };
}

export type DetectionSensitivity = 'relaxed' | 'standard' | 'sensitive';

// Cleaning/maintenance counters since the last "Cleaned" reset.
export interface MaintenanceState {
  cooksSinceClean: number;
  runSecondsSinceClean: number;
  flareupsSinceClean: number;
  cleanedAt: number;
}

// Estimated pellet level, derived from cumulative auger run-time. Rough by
// nature — the feed rate is tunable and the user recalibrates via "Refilled".
export interface PelletState {
  capacityLbs: number;        // hopper size
  feedRateLbsPerHr: number;   // pounds consumed per hour of auger run-time
  augerSeconds: number;       // cumulative auger-on seconds since last refill
  refilledAt: number;         // epoch ms of last refill
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
  // Component activity (on at any point in this interval). Optional so older
  // cook files without them still parse.
  auger?: boolean;              // motorState
  fan?: boolean;                // fanState
  igniter?: boolean;            // hotState (hot rod)
}

// Summary of a saved cook session.
export interface CookMeta {
  id: string;                   // file stem, e.g. '2026-06-23T18-30-00'
  startedAt: number;            // epoch ms
  endedAt: number | null;       // null while still running
  samples: number;              // sample count
  device?: string;
  labels?: Record<number, string>;  // probe names captured at cook start
  name?: string;                // optional user name/note (session manager)
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
  deleteCook: 'pitboss:cooks:delete',  // remove a saved cook (session manager)
  renameCook: 'pitboss:cooks:rename',  // set/clear a cook's name/note
  shutdown: 'pitboss:shutdown',    // renderer -> main: 'auto' | 'now' | 'cancel'
  cleaned: 'pitboss:cleaned',      // renderer -> main: reset maintenance counters
  getLoginItem: 'pitboss:login:get',
  btSettings: 'pitboss:bluetooth:settings',  // open the macOS Bluetooth privacy pane
  setLoginItem: 'pitboss:login:set',
  cooking: 'pitboss:cooking',       // the shared cuts/methods catalogue (read once)
  cookEvents: 'pitboss:cooks:events',  // interruption events for the active cook
} as const;

export type ShutdownMode = 'auto' | 'now' | 'cancel';

// A cook event — something that happened to the cook rather than a reading.
//
// Written to the same JSONL file as the samples, but keyed by `at` rather than
// `t` precisely so the sample reader ignores them: any line with a numeric `t`
// is a sample, so an event that used `t` would be read back as a reading of
// nothing. iOS writes the identical shape (ios/.../CookStore.swift) — the two
// apps read each other's cook files.
export type CookEventKind =
  | 'grill-off' | 'grill-on' | 'out-of-pellets'
  | 'link-lost' | 'link-restored' | 'app-resumed' | 'method-started';

export interface CookEvent {
  at: number;          // epoch ms
  kind: CookEventKind;
  note?: string;
}

export const COOK_EVENT_LABELS: Record<CookEventKind, string> = {
  'grill-off': 'Grill off',
  'grill-on': 'Grill relit',
  'out-of-pellets': 'Out of pellets',
  'link-lost': 'Lost connection',
  'link-restored': 'Reconnected',
  'app-resumed': 'App resumed',
  'method-started': 'Method started',
};

// Whether this interrupted the cook itself rather than just the record.
export function interruptedTheCook(kind: CookEventKind): boolean {
  return kind === 'grill-off' || kind === 'out-of-pellets';
}
