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
  probeLabels?: Record<number, string>;
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
// The controller can hold a target only for the first two probes (the sidecar's
// set_probe rejects the rest); probes beyond this are read-only monitors.
const SETTABLE_PROBES = 2;
// Optional user labels per probe ("Chicken", "Pork Shoulder"), persisted and
// snapshotted into each recorded cook so past sessions show what was cooking.
const probeLabels: Record<number, string> = {};

// Escape user text before it goes into an innerHTML attribute value.
function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/"/g, '&quot;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

// Display name for a probe: its custom label, else "Probe N".
function probeLabel(i: number): string {
  return probeLabels[i]?.trim() || `Probe ${i}`;
}

// Set a probe's target: remember it, persist, and push to the grill (1-2 only).
function setProbeTarget(probe: number): void {
  const input = document.getElementById(`p${probe}Target`) as HTMLInputElement | null;
  if (!input) return;
  const val = Number(input.value);
  if (!input.value.trim() || !Number.isFinite(val)) return toast('Enter a probe target', true);
  probeTargets[probe] = val;
  persist({ probeTargets });
  renderState();
  run(`${probeLabel(probe)} → ${val}${unit()}`, window.pitboss.setProbe(probe, val));
}

// Remove a probe's target — forgets it locally (stops the app's reached-target
// alert). The grill keeps its own IT target until changed on the controller.
function clearProbeTarget(probe: number): void {
  delete probeTargets[probe];
  persist({ probeTargets });
  const input = document.getElementById(`p${probe}Target`) as HTMLInputElement | null;
  if (input) input.value = '';
  renderState();
  toast(`${probeLabel(probe)} target cleared`);
}
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
  ['offBtn', 'lightBtn', 'primeBtn', 'refreshBtn']
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
    // Tapping a preset sets the grill immediately — no separate confirm button.
    chip.addEventListener('click', () => {
      setTempValue = t;
      userEditSetpoint();
      run(`Grill → ${t}${unit()}`, window.pitboss.setTemp(t));
    });
    wrap.appendChild(chip);
  }

  // Probe rows. Only probes 1-2 accept a target on this controller (see the
  // sidecar's set_probe); the rest are read-only temperature monitors.
  const probes = $('probes');
  probes.innerHTML = '';
  for (let i = 1; i <= caps.meat_probes; i++) {
    const settable = i <= SETTABLE_PROBES;
    const row = document.createElement('div');
    row.className = 'probe-row';
    row.innerHTML = `
      <span class="probe-status">
        <span class="probe-dot off" id="p${i}Dot"></span>
        <span class="probe-id">
          <input class="probe-label" id="p${i}Label" placeholder="Probe ${i}"
                 maxlength="24" value="${esc(probeLabels[i] ?? '')}" />
          <span class="probe-sub" id="p${i}Sub">Not connected</span>
        </span>
      </span>
      <span class="probe-temp" id="p${i}Temp">--<span class="pu">${unit()}</span></span>
      ${settable ? `
      <span class="probe-target">
        <input type="number" id="p${i}Target" class="probe-input" placeholder="target"
               value="${probeTargets[i] ?? ''}" />
        <button class="probe-set" data-probe="${i}">Set</button>
        <button class="probe-clear" data-clear="${i}" title="Clear target" aria-label="Clear target">✕</button>
      </span>` : `<span class="probe-monitor">monitor</span>`}`;
    probes.appendChild(row);
  }
  probes.querySelectorAll<HTMLButtonElement>('button[data-probe]').forEach((b) => {
    b.addEventListener('click', () => setProbeTarget(Number(b.dataset.probe)));
  });
  probes.querySelectorAll<HTMLButtonElement>('button[data-clear]').forEach((b) => {
    b.addEventListener('click', () => clearProbeTarget(Number(b.dataset.clear)));
  });
  probes.querySelectorAll<HTMLInputElement>('.probe-input').forEach((inp) => {
    inp.addEventListener('keydown', (e) => {
      if (e.key === 'Enter') setProbeTarget(Number(inp.id.replace(/\D/g, '')));
    });
  });
  probes.querySelectorAll<HTMLInputElement>('.probe-label').forEach((inp) => {
    const save = () => {
      const i = Number(inp.id.replace(/\D/g, ''));
      const v = inp.value.trim();
      if (v) probeLabels[i] = v; else delete probeLabels[i];
      persist({ probeLabels });
      renderChart();           // reflect the new name in the chart headers
    };
    inp.addEventListener('change', save);
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
interface ChartSeries { key: keyof Sample; color: string; dash?: number[]; }
interface ChartGroup { id: string; label: string; readKey: keyof Sample; series: ChartSeries[]; }
// One chart per source: the grill (with its dashed setpoint) and each probe.
const CHART_GROUPS: ChartGroup[] = [
  { id: 'grill', label: 'Grill', readKey: 'grillTemp', series: [
      { key: 'grillTemp', color: '#ff6b1a' },
      { key: 'grillSetTemp', color: '#ffcf4d', dash: [4, 4] } ] },
  { id: 'p1', label: 'Probe 1', readKey: 'p1Temp', series: [{ key: 'p1Temp', color: '#5aa9e6' }] },
  { id: 'p2', label: 'Probe 2', readKey: 'p2Temp', series: [{ key: 'p2Temp', color: '#4ccf6a' }] },
  { id: 'p3', label: 'Probe 3', readKey: 'p3Temp', series: [{ key: 'p3Temp', color: '#c98be0' }] },
  { id: 'p4', label: 'Probe 4', readKey: 'p4Temp', series: [{ key: 'p4Temp', color: '#e88f5a' }] },
];

function groupHasData(g: ChartGroup, samples: Sample[]): boolean {
  for (const s of samples) for (const ser of g.series) if (s[ser.key] != null) return true;
  return false;
}
function lastValue(samples: Sample[], key: keyof Sample): number | null {
  for (let i = samples.length - 1; i >= 0; i--) {
    const v = samples[i][key] as number | null;
    if (v != null) return v;
  }
  return null;
}

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

// Draw one source's series into its own canvas, auto-scaled to just that data
// so a 140° probe and a 250° grill each use the full height.
function drawSeriesChart(canvas: HTMLCanvasElement, series: ChartSeries[], samples: Sample[]): void {
  const ctx = canvas.getContext('2d');
  if (!ctx) return;
  const dpr = window.devicePixelRatio || 1;
  const cssW = canvas.clientWidth || 320;
  const cssH = canvas.clientHeight || 72;
  canvas.width = Math.round(cssW * dpr);
  canvas.height = Math.round(cssH * dpr);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, cssW, cssH);
  ctx.font = '10px -apple-system, system-ui, sans-serif';

  let vMin = Infinity, vMax = -Infinity;
  for (const s of samples) for (const ser of series) {
    const v = s[ser.key] as number | null;
    if (v == null) continue;
    if (v < vMin) vMin = v;
    if (v > vMax) vMax = v;
  }
  if (!isFinite(vMin)) return;

  const padL = 30, padR = 8, padT = 6, padB = 14;
  const plotW = cssW - padL - padR;
  const plotH = cssH - padT - padB;
  const range = Math.max(6, (vMax - vMin) * 0.12);
  vMin = Math.floor((vMin - range) / 10) * 10;
  vMax = Math.ceil((vMax + range) / 10) * 10;
  if (vMax === vMin) vMax += 10;

  const tMin = samples[0].t;
  const tMax = samples[samples.length - 1].t;
  const tSpan = Math.max(1, tMax - tMin);
  const x = (t: number) => padL + ((t - tMin) / tSpan) * plotW;
  const y = (v: number) => padT + (1 - (v - vMin) / (vMax - vMin)) * plotH;

  // Horizontal gridlines + y-axis labels (few, since each chart is short).
  ctx.strokeStyle = 'rgba(255,255,255,0.06)';
  ctx.fillStyle = '#a8927c';
  ctx.textBaseline = 'middle';
  const ticks = 2;
  for (let i = 0; i <= ticks; i++) {
    const v = vMin + (i / ticks) * (vMax - vMin);
    const yy = y(v);
    ctx.beginPath(); ctx.moveTo(padL, yy); ctx.lineTo(cssW - padR, yy); ctx.stroke();
    ctx.fillText(String(Math.round(v)), 4, yy);
  }

  // Series lines (gaps where a probe was unplugged).
  ctx.lineWidth = 1.5;
  for (const ser of series) {
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

// Build/update one mini-chart per source that has data; drop those that don't.
function renderChart(): void {
  const samples = activeSamples();
  const container = $('charts');
  let anyData = false;

  for (const g of CHART_GROUPS) {
    const domId = `chart-${g.id}`;
    let el = document.getElementById(domId) as HTMLDivElement | null;
    if (!groupHasData(g, samples)) { if (el) el.remove(); continue; }
    anyData = true;

    if (!el) {
      el = document.createElement('div');
      el.id = domId;
      el.className = 'mini-chart';
      el.innerHTML =
        `<div class="mini-head">` +
        `<span class="mini-label"><span class="swatch" style="background:${g.series[0].color}"></span>` +
        `<span class="mini-label-text" id="mini-lbl-${g.id}"></span></span>` +
        `<span class="mini-val" id="mini-val-${g.id}"></span></div>` +
        `<canvas class="mini-canvas"></canvas>`;
    }
    container.appendChild(el); // (re)append in CHART_GROUPS order

    const lblEl = document.getElementById(`mini-lbl-${g.id}`);
    if (lblEl) lblEl.textContent = g.id === 'grill' ? 'Grill' : probeLabel(Number(g.id.replace(/\D/g, '')));

    const cur = lastValue(samples, g.readKey);
    const valEl = document.getElementById(`mini-val-${g.id}`);
    if (valEl) {
      let txt = cur != null ? `${cur}${unit()}` : '--';
      if (g.id === 'grill') {
        const sv = lastValue(samples, 'grillSetTemp');
        if (sv != null) txt += `  ·  set ${sv}${unit()}`;
      }
      valEl.textContent = txt;
    }
    drawSeriesChart(el.querySelector('canvas') as HTMLCanvasElement, g.series, samples);
  }

  // Empty-state note when nothing has data yet.
  let note = document.getElementById('charts-empty');
  if (!anyData) {
    if (!note) {
      note = document.createElement('div');
      note.id = 'charts-empty';
      note.className = 'charts-empty';
      note.textContent = 'No temperature data yet';
      container.appendChild(note);
    }
  } else if (note) {
    note.remove();
  }
}

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
    const tempEl = document.getElementById(`p${i}Temp`);
    if (!tempEl) continue;
    const v = (state as any)[`p${i}Temp`] as number | null;
    tempEl.innerHTML = (v != null ? String(v) : '--') + `<span class="pu">${unit()}</span>`;

    // Prefer the grill's OWN target (what drives its "IT" alert) over the app's.
    const target = grillProbeTarget(i) ?? probeTargets[i] ?? null;
    const reached = v != null && target != null && v >= target;
    tempEl.classList.toggle('reached', reached);

    // Status dot + subline: unplugged / monitoring / counting down / at target.
    let cls: string, text: string;
    if (v == null) { cls = 'off'; text = 'Not connected'; }
    else if (target == null) { cls = 'ok'; text = 'Monitoring'; }
    else if (reached) { cls = 'done'; text = `At target ${target}${unit()} ✓`; }
    else { cls = 'warn'; text = `${target - v}° to go · target ${target}${unit()}`; }
    const dot = document.getElementById(`p${i}Dot`);
    const sub = document.getElementById(`p${i}Sub`);
    if (dot) dot.className = 'probe-dot ' + cls;
    if (sub) sub.textContent = text;
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
    // Replace (not merge) so a target/label the user cleared doesn't reappear
    // from our built-in defaults.
    if (s.probeTargets) {
      for (const k of Object.keys(probeTargets)) delete probeTargets[+k];
      Object.assign(probeTargets, s.probeTargets);
    }
    if (s.probeLabels) Object.assign(probeLabels, s.probeLabels);
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
