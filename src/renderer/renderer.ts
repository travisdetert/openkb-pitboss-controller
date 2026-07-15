// NOTE: this file is deliberately NOT an ES module (no import/export) so tsc
// emits a plain browser script with no require()/exports references. Types are
// declared locally; they mirror src/shared/protocol.ts (kept small on purpose).

interface GrillState {
  moduleIsOn?: boolean;
  err1?: boolean; err2?: boolean; err3?: boolean;
  highTempErr?: boolean; fanErr?: boolean; hotErr?: boolean;
  motorErr?: boolean; noPellets?: boolean; erL?: boolean;
  fanState?: boolean; hotState?: boolean; motorState?: boolean;
  lightState?: boolean; primeState?: boolean;
  recipeStep?: number; recipeTime?: number;
  p1Target?: number | null; p1Temp?: number | null;
  p2Temp?: number | null; p3Temp?: number | null; p4Temp?: number | null;
  grillSetTemp?: number | null; grillTemp?: number | null;
  smokerActTemp?: number | null; isFahrenheit?: boolean;
  __device?: string;
}
interface Capabilities {
  type: 'capabilities';
  model: string; min_temp: number; max_temp: number;
  temp_increments: number[]; meat_probes: number; has_lights: boolean;
}
interface ScanDevice { name: string; rssi: number; }
interface Settings {
  setpoint: number;
  probeTargets: Record<number, number>;
  grillName: string;
  grillModel: string;
}
interface Sample {
  t: number;
  grillTemp: number | null;
  grillSetTemp: number | null;
  p1Temp: number | null; p2Temp: number | null;
  p3Temp: number | null; p4Temp: number | null;
}
interface CookMeta {
  id: string; startedAt: number; endedAt: number | null;
  samples: number; device?: string;
}
type SidecarEvent =
  | { type: 'ready'; model_default: string; name_default: string }
  | { type: 'status'; connected: boolean; connecting: boolean; reason: string; device?: string }
  | Capabilities
  | { type: 'state'; data: GrillState }
  | { type: 'scan_result'; id?: number; devices: ScanDevice[] }
  | { type: 'ack'; id?: number; ok: true; result: unknown }
  | { type: 'error'; id?: number; ok: false; message: string };

interface PitbossApi {
  connect(name?: string, model?: string): Promise<unknown>;
  disconnect(): Promise<unknown>;
  scan(seconds?: number): Promise<ScanDevice[]>;
  setTemp(value: number): Promise<unknown>;
  setProbe(probe: number, value: number): Promise<unknown>;
  light(on: boolean): Promise<unknown>;
  prime(on: boolean): Promise<unknown>;
  off(): Promise<unknown>;
  refresh(): Promise<unknown>;
  getSettings(): Promise<Settings>;
  setSettings(patch: Partial<Settings>): Promise<Settings>;
  getHistory(): Promise<Sample[]>;
  listCooks(): Promise<CookMeta[]>;
  readCook(id: string): Promise<Sample[]>;
  onEvent(cb: (evt: SidecarEvent) => void): () => void;
}
interface Window { pitboss: PitbossApi; }

const $ = <T extends HTMLElement = HTMLElement>(id: string) =>
  document.getElementById(id) as T;

// ---- local UI state --------------------------------------------------------
let caps: Capabilities | null = null;
let state: GrillState = {};
let connected = false;
let connecting = false;
let wantConnection = true;   // user intent; the sidecar auto-retries while true
let setTempValue = 225;       // pending setpoint shown in the stepper
// Once the user adjusts the stepper we stop mirroring the grill's own setpoint
// into it (so we don't fight their edit); reset on each fresh connect.
let userSetTarget = false;
const probeTargets: Record<number, number> = { 1: 145, 2: 165 };
let grillName = 'PBL-';
let grillModel = 'PB1100PSC3';

// Temperature history: a buffer of live samples plus a "viewing" mode that can
// instead show a past cook (null = follow live).
let liveSamples: Sample[] = [];
let viewCookId: string | null = null;
let viewSamples: Sample[] = [];        // populated when viewing a past cook
const MAX_LIVE_SAMPLES = 4320;          // ~6h at one point per 5s
let lastSampleT = 0;

const unit = () => (state.isFahrenheit === false ? '°C' : '°F');

// ---- settings persistence --------------------------------------------------
// Debounce writes so dragging the stepper doesn't spam the disk.
let saveTimer: number | undefined;
function persist(patch: Partial<Settings>): void {
  window.clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => { void window.pitboss.setSettings(patch); }, 300);
}

// ---- toast -----------------------------------------------------------------
let toastTimer: number | undefined;
function toast(msg: string, isErr = false): void {
  const el = $('toast');
  el.textContent = msg;
  el.className = 'toast' + (isErr ? ' err' : '');
  window.clearTimeout(toastTimer);
  toastTimer = window.setTimeout(() => el.classList.add('hidden'), 2600);
}

async function run(label: string, p: Promise<unknown>): Promise<void> {
  try {
    await p;
    toast(label);
  } catch (e) {
    toast(`${label} failed: ${(e as Error).message}`, true);
  }
}

// ---- rendering -------------------------------------------------------------
function clampTemp(v: number): number {
  const lo = caps?.min_temp ?? 180;
  const hi = caps?.max_temp ?? 500;
  return Math.max(lo, Math.min(hi, v));
}

function renderConnection(): void {
  const btn = $('connBtn');
  const label = $('connLabel');
  // While the user wants a connection, the sidecar keeps retrying — present
  // that as a steady "Connecting…" rather than flickering to "Connect".
  const retrying = wantConnection && !connected;
  const st = connected ? 'connected' : retrying ? 'connecting' : 'disconnected';
  btn.dataset.state = st;
  label.textContent =
    connected ? (state.__device || 'Connected') :
    retrying ? 'Connecting…' :
    'Connect';

  const main = $('app');
  main.classList.toggle('disconnected', !connected);

  // Enable/disable controls.
  const enable = connected;
  ['setBtn', 'offBtn', 'lightBtn', 'primeBtn', 'refreshBtn']
    .forEach((id) => {
      const el = document.getElementById(id) as HTMLButtonElement | null;
      if (el) el.disabled = !enable;
    });
  document.querySelectorAll<HTMLButtonElement>('.chip, .probe-target button, .probe-target input')
    .forEach((el) => (el.disabled = !enable));
}

// Some models (e.g. PB1100PSC3) report no temp_increments in the pytboss data,
// which would leave the quick-set row empty. Fall back to a sensible spread,
// clipped to the model's own min/max so we never offer an out-of-range preset.
const FALLBACK_INCREMENTS = [200, 225, 250, 275, 300, 350, 400];
function presetIncrements(c: Capabilities): number[] {
  if (c.temp_increments && c.temp_increments.length) return c.temp_increments;
  return FALLBACK_INCREMENTS.filter((t) => t >= c.min_temp && t <= c.max_temp);
}

function renderCaps(): void {
  if (!caps) return;
  // Presets from the model's temp increments (or a fallback spread if none).
  const wrap = $('presets');
  wrap.innerHTML = '';
  for (const t of presetIncrements(caps)) {
    const chip = document.createElement('button');
    chip.className = 'chip';
    chip.textContent = String(t);
    chip.dataset.temp = String(t);
    chip.addEventListener('click', () => { setTempValue = t; userEditSetpoint(); });
    wrap.appendChild(chip);
  }

  // Probe rows.
  const probes = $('probes');
  probes.innerHTML = '';
  for (let i = 1; i <= caps.meat_probes; i++) {
    const row = document.createElement('div');
    row.className = 'probe-row';
    row.innerHTML = `
      <span class="probe-id">
        <span class="probe-name">Probe ${i}</span>
        <span class="probe-grill" id="p${i}Grill"></span>
      </span>
      <span class="probe-temp" id="p${i}Temp">--<span class="pu">${unit()}</span></span>
      <span class="probe-target">
        <input type="number" id="p${i}Target" value="${probeTargets[i] ?? ''}" />
        <button data-probe="${i}">Set</button>
      </span>`;
    probes.appendChild(row);
  }
  probes.querySelectorAll<HTMLButtonElement>('button[data-probe]').forEach((b) => {
    b.addEventListener('click', () => {
      const probe = Number(b.dataset.probe);
      const input = $(`p${probe}Target`) as HTMLInputElement;
      const val = Number(input.value);
      if (!Number.isFinite(val)) return toast('Enter a probe target', true);
      probeTargets[probe] = val;
      persist({ probeTargets });
      run(`Probe ${probe} → ${val}${unit()}`, window.pitboss.setProbe(probe, val));
    });
  });

  // Light only if the model actually has a controllable light.
  $('lightBtn').classList.toggle('hidden', !caps.has_lights);
}

// Reflect the selected target by highlighting its preset chip, without persisting.
function showSetpoint(): void {
  setTempValue = clampTemp(setTempValue);
  document.querySelectorAll<HTMLButtonElement>('.chip').forEach((c) => {
    c.classList.toggle('active', Number(c.dataset.temp) === setTempValue);
  });
}

// Show + remember the current target. Used for both restored settings and the
// mirrored grill setpoint; user-driven changes also flip userSetTarget (below).
function renderSetpoint(): void {
  showSetpoint();
  persist({ setpoint: setTempValue });
}

// A user edited the stepper: stop mirroring the grill until the next connect.
function userEditSetpoint(): void {
  userSetTarget = true;
  renderSetpoint();
}

function led(id: string, on: boolean, hot = false): void {
  const el = document.getElementById(id);
  if (!el) return;
  el.className = 'led' + (on ? (hot ? ' hot' : ' on') : '');
}

// ---- temperature chart -----------------------------------------------------
interface Series { key: keyof Sample; label: string; color: string; dash?: number[]; }
const SERIES: Series[] = [
  { key: 'grillTemp', label: 'Grill', color: '#ff6b1a' },
  { key: 'grillSetTemp', label: 'Set', color: '#ffcf4d', dash: [4, 4] },
  { key: 'p1Temp', label: 'Probe 1', color: '#5aa9e6' },
  { key: 'p2Temp', label: 'Probe 2', color: '#4ccf6a' },
  { key: 'p3Temp', label: 'Probe 3', color: '#c98be0' },
  { key: 'p4Temp', label: 'Probe 4', color: '#e88f5a' },
];

const activeSamples = () => (viewCookId ? viewSamples : liveSamples);

const clock = (t: number) =>
  new Date(t).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

// Capture a live point, throttled to ~1/5s to mirror the main-process recorder.
function pushLiveSample(): void {
  const now = Date.now();
  if (liveSamples.length && now - lastSampleT < 5000) return;
  lastSampleT = now;
  liveSamples.push({
    t: now,
    grillTemp: state.grillTemp ?? null,
    grillSetTemp: state.grillSetTemp ?? null,
    p1Temp: state.p1Temp ?? null, p2Temp: state.p2Temp ?? null,
    p3Temp: state.p3Temp ?? null, p4Temp: state.p4Temp ?? null,
  });
  if (liveSamples.length > MAX_LIVE_SAMPLES) liveSamples.shift();
}

function drawChart(): void {
  const canvas = $('chart') as HTMLCanvasElement;
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  const dpr = window.devicePixelRatio || 1;
  const cssW = canvas.clientWidth || 360;
  const cssH = canvas.clientHeight || 150;
  canvas.width = Math.round(cssW * dpr);
  canvas.height = Math.round(cssH * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, cssW, cssH);
  ctx.font = '10px -apple-system, system-ui, sans-serif';

  const samples = activeSamples();
  let vMin = Infinity, vMax = -Infinity;
  for (const s of samples) for (const ser of SERIES) {
    const v = s[ser.key] as number | null;
    if (v == null) continue;
    if (v < vMin) vMin = v;
    if (v > vMax) vMax = v;
  }
  if (!isFinite(vMin)) {
    ctx.fillStyle = '#a8927c';
    ctx.textAlign = 'center';
    ctx.fillText('No temperature data yet', cssW / 2, cssH / 2);
    ctx.textAlign = 'left';
    return;
  }

  const padL = 30, padR = 8, padT = 8, padB = 16;
  const plotW = cssW - padL - padR;
  const plotH = cssH - padT - padB;
  const range = Math.max(10, (vMax - vMin) * 0.12);
  vMin = Math.floor((vMin - range) / 10) * 10;
  vMax = Math.ceil((vMax + range) / 10) * 10;
  if (vMax === vMin) vMax += 10;

  const tMin = samples[0].t;
  const tMax = samples[samples.length - 1].t;
  const tSpan = Math.max(1, tMax - tMin);
  const x = (t: number) => padL + ((t - tMin) / tSpan) * plotW;
  const y = (v: number) => padT + (1 - (v - vMin) / (vMax - vMin)) * plotH;

  // Horizontal gridlines + y-axis labels.
  ctx.strokeStyle = 'rgba(255,255,255,0.06)';
  ctx.fillStyle = '#a8927c';
  ctx.textBaseline = 'middle';
  const ticks = 4;
  for (let i = 0; i <= ticks; i++) {
    const v = vMin + (i / ticks) * (vMax - vMin);
    const yy = y(v);
    ctx.beginPath(); ctx.moveTo(padL, yy); ctx.lineTo(cssW - padR, yy); ctx.stroke();
    ctx.fillText(String(Math.round(v)), 4, yy);
  }

  // Series lines (gaps where a probe was unplugged).
  ctx.lineWidth = 1.5;
  for (const ser of SERIES) {
    ctx.beginPath();
    ctx.strokeStyle = ser.color;
    ctx.setLineDash(ser.dash || []);
    let started = false;
    for (const s of samples) {
      const v = s[ser.key] as number | null;
      if (v == null) { started = false; continue; }
      const px = x(s.t), py = y(v);
      if (!started) { ctx.moveTo(px, py); started = true; } else ctx.lineTo(px, py);
    }
    ctx.stroke();
  }
  ctx.setLineDash([]);

  // X-axis: start and end clock times.
  ctx.fillStyle = '#a8927c';
  ctx.textBaseline = 'bottom';
  ctx.fillText(clock(tMin), padL, cssH);
  const end = clock(tMax);
  ctx.fillText(end, cssW - padR - ctx.measureText(end).width, cssH);
}

function renderLegend(): void {
  const samples = activeSamples();
  const present = new Set<string>();
  for (const s of samples) for (const ser of SERIES) {
    if ((s[ser.key] as number | null) != null) present.add(ser.key as string);
  }
  const wrap = $('chartLegend');
  wrap.innerHTML = '';
  for (const ser of SERIES) {
    if (!present.has(ser.key as string)) continue;
    const k = document.createElement('span');
    k.className = 'key';
    k.innerHTML = `<span class="swatch" style="background:${ser.color}"></span>${ser.label}`;
    wrap.appendChild(k);
  }
}

function renderChart(): void { drawChart(); renderLegend(); }

async function refreshCookList(): Promise<CookMeta[]> {
  let cooks: CookMeta[] = [];
  try { cooks = await window.pitboss.listCooks(); } catch { /* ignore */ }
  const sel = $('cookSelect') as HTMLSelectElement;
  const cur = sel.value;
  sel.innerHTML = '<option value="">● Live</option>';
  for (const c of cooks) {
    const o = document.createElement('option');
    o.value = c.id;
    const d = new Date(c.startedAt);
    const date = d.toLocaleDateString([], { month: 'short', day: 'numeric' });
    o.textContent = `${date} ${clock(c.startedAt)}` + (c.endedAt === null ? ' · live' : '');
    sel.appendChild(o);
  }
  sel.value = cur;
  return cooks;
}

function wireChart(): void {
  const sel = $('cookSelect') as HTMLSelectElement;
  sel.addEventListener('mousedown', () => { void refreshCookList(); });
  sel.addEventListener('change', async () => {
    const id = sel.value;
    if (!id) { viewCookId = null; viewSamples = []; }
    else { viewCookId = id; viewSamples = await window.pitboss.readCook(id); }
    renderChart();
  });
  window.addEventListener('resize', renderChart);
}

async function hydrateHistory(): Promise<void> {
  const cooks = await refreshCookList();
  // If a cook is still recording (e.g. the renderer was reloaded mid-smoke),
  // seed the live buffer from it so the graph isn't blank.
  if (cooks[0] && cooks[0].endedAt === null) {
    try { liveSamples = await window.pitboss.getHistory(); } catch { /* ignore */ }
  }
  renderChart();
}

// The grill only reports a target for probe 1 (p1Target). 960 is pytboss's
// "unset / probe unplugged" sentinel; ignore it and other implausible values.
function grillProbeTarget(i: number): number | null {
  const v = (state as any)[`p${i}Target`] as number | null | undefined;
  if (v == null || v === 960 || v < 50 || v > 600) return null;
  return v;
}

function renderState(): void {
  $('unit').textContent = unit();
  $('grillTemp').textContent =
    state.grillTemp != null ? String(state.grillTemp) : '--';
  $('grillSetLabel').textContent =
    state.grillSetTemp != null ? `set ${state.grillSetTemp}${unit()}` : '— —';

  for (let i = 1; i <= 4; i++) {
    const el = document.getElementById(`p${i}Temp`);
    if (!el) continue;
    const v = (state as any)[`p${i}Temp`] as number | null;
    el.innerHTML = (v != null ? String(v) : '--') + `<span class="pu">${unit()}</span>`;

    // Show the grill's OWN probe target (what drives its "IT" alert), which can
    // differ from the value you typed. Highlight when the reading hits it.
    const gt = grillProbeTarget(i);
    const grillEl = document.getElementById(`p${i}Grill`);
    if (grillEl) grillEl.textContent = gt != null ? `target ${gt}${unit()}` : '';
    el.classList.toggle('reached', v != null && gt != null && v >= gt);
  }

  led('ledFan', !!state.fanState);
  led('ledHot', !!state.hotState, true);
  led('ledMotor', !!state.motorState);
  led('ledModule', !!state.moduleIsOn);

  // Errors.
  const errs: string[] = [];
  if (state.noPellets) errs.push('Out of pellets');
  if (state.highTempErr) errs.push('High-temp error');
  if (state.fanErr) errs.push('Fan error');
  if (state.hotErr) errs.push('Igniter error');
  if (state.motorErr) errs.push('Auger error');
  if (state.err1 || state.err2 || state.err3) errs.push('Controller error');
  const banner = $('errBanner');
  if (errs.length) {
    banner.textContent = '⚠ ' + errs.join(' · ');
    banner.classList.remove('hidden');
  } else {
    banner.classList.add('hidden');
  }

  // Light button reflects state.
  const lightBtn = $('lightBtn');
  lightBtn.textContent = state.lightState ? 'Light: On' : 'Light: Off';
  lightBtn.classList.toggle('active', !!state.lightState);

  // Prime button lights up when the grill reports the primer motor running —
  // real confirmation the command took effect (independent of our countdown).
  if (!priming) {
    $('primeBtn').classList.toggle('active', !!state.primeState);
  }
}

// ---- event wiring ----------------------------------------------------------
function wireControls(): void {
  $('connBtn').addEventListener('click', () => {
    if (connected || wantConnection) {
      // Connected, or mid-retry: a click cancels/disconnects.
      wantConnection = false;
      run('Disconnected', window.pitboss.disconnect());
      renderConnection();
    } else {
      wantConnection = true;
      renderConnection();
      window.pitboss.connect(grillName, grillModel).catch(() => { /* status events surface it */ });
    }
  });

  $('setBtn').addEventListener('click', () =>
    run(`Grill → ${setTempValue}${unit()}`, window.pitboss.setTemp(setTempValue)));

  $('offBtn').addEventListener('click', () => {
    if (confirm('Turn the grill off?')) run('Turning off', window.pitboss.off());
  });

  $('lightBtn').addEventListener('click', () =>
    run('Toggling light', window.pitboss.light(!state.lightState)));
  $('primeBtn').addEventListener('click', () => { void primeBurst(); });
  $('refreshBtn').addEventListener('click', () =>
    run('Refreshed', window.pitboss.refresh()));
}

// Prime is a momentary motor run: on, then off after a few seconds. Give
// immediate, continuous feedback (countdown + highlight) since a click on the
// grill side is otherwise invisible — and confirm via the grill's primeState.
let priming = false;
const PRIME_SECONDS = 5;
async function primeBurst(): Promise<void> {
  if (priming) return;
  // Most Pit Boss boards only run the primer from the off/idle state; priming
  // mid-cook is usually a no-op. Warn rather than silently do nothing.
  if (state.moduleIsOn &&
      !confirm("The grill is running.\n\nPriming usually only works while it's "
             + 'off (e.g. to reload the firepot after running out of pellets). '
             + 'Prime anyway?')) {
    return;
  }
  priming = true;
  const btn = $('primeBtn') as HTMLButtonElement;
  const orig = btn.textContent || 'Prime Auger';
  btn.classList.add('active');
  toast('Priming auger…');
  try {
    await window.pitboss.prime(true);
    for (let s = PRIME_SECONDS; s > 0; s--) {
      btn.textContent = `Priming… ${s}s`;
      await new Promise((r) => setTimeout(r, 1000));
    }
    await window.pitboss.prime(false);
    toast('Auger primed');
  } catch (e) {
    toast(`Prime failed: ${(e as Error).message}`, true);
  } finally {
    btn.classList.remove('active');
    btn.textContent = orig;
    priming = false;
  }
}

// ---- sidecar events --------------------------------------------------------
function handleEvent(evt: SidecarEvent): void {
  switch (evt.type) {
    case 'ready':
      break;
    case 'status': {
      const was = connected;
      connected = evt.connected;
      connecting = evt.connecting;
      if (evt.device) state.__device = evt.device;
      // On a fresh connection, adopt the grill's own setpoint (arrives with the
      // next state frame) rather than a stale remembered value.
      if (connected && !was) userSetTarget = false;
      // Toast only on meaningful transitions, not on every auto-retry cycle.
      if (connected && !was) toast(`Connected to ${evt.device || 'grill'}`);
      else if (was && !connected) toast('Lost connection — reconnecting…', true);
      renderConnection();
      break;
    }
    case 'capabilities':
      caps = evt;
      setTempValue = clampTemp(setTempValue);
      renderCaps();
      renderSetpoint();
      renderConnection();
      break;
    case 'state': {
      const wasOn = state.moduleIsOn;
      state = { ...state, ...evt.data };
      // Mirror the grill's own setpoint into the stepper until the user edits it,
      // so the target reflects what the grill is actually set to (not a stale value).
      if (!userSetTarget && typeof state.grillSetTemp === 'number'
          && state.grillSetTemp !== setTempValue) {
        setTempValue = state.grillSetTemp;
        renderSetpoint();
      }
      // A fresh power-on starts a new cook — clear the live curve so cooks
      // don't visually run together within one app session.
      if (state.moduleIsOn && !wasOn) { liveSamples = []; lastSampleT = 0; }
      renderState();
      pushLiveSample();
      if (!viewCookId) renderChart();
      break;
    }
    case 'error':
      toast(evt.message, true);
      break;
  }
}

// ---- boot ------------------------------------------------------------------
async function boot(): Promise<void> {
  window.pitboss.onEvent(handleEvent);
  wireControls();
  wireChart();

  // Restore remembered settings before first render / connect.
  try {
    const s = await window.pitboss.getSettings();
    if (typeof s.setpoint === 'number') setTempValue = s.setpoint;
    if (s.probeTargets) Object.assign(probeTargets, s.probeTargets);
    if (s.grillName) grillName = s.grillName;
    if (s.grillModel) grillModel = s.grillModel;
  } catch { /* defaults are fine */ }

  renderSetpoint();
  renderConnection();
  await hydrateHistory();

  // Auto-connect on launch — it's a single-purpose appliance controller.
  window.pitboss.connect(grillName, grillModel).catch(() => { /* surfaced via status events */ });
}

void boot();
