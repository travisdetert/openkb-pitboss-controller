import { app, BrowserWindow, ipcMain, Notification } from 'electron';
import * as fs from 'fs';
import * as path from 'path';
import { initLogging, attachRendererConsole, log } from './log';
import { Sidecar } from './sidecar';
import { SettingsStore } from './store';
import { Recorder } from './recorder';
import { TrayManager } from './tray';
import { advanceShutdown, beginShutdown, SHUTDOWN, ShutdownPhase } from './shutdown';
import { GrillCommand, GrillState, IPC, Settings, ShutdownMode, SidecarEvent } from '../shared/protocol';

// Project root = two levels up from dist/main/.
const PROJECT_ROOT = path.resolve(__dirname, '..', '..');
const ICON_PATH = path.join(PROJECT_ROOT, 'build', 'icon.png');
// Tray template icon ships in dist/ so it's present in the packaged bundle.
const TRAY_ICON = path.join(__dirname, '..', 'assets', 'trayTemplate.png');

let win: BrowserWindow | null = null;
let sidecar: Sidecar | null = null;
let store: SettingsStore | null = null;
let recorder: Recorder | null = null;
let tray: TrayManager | null = null;
let wasConnected = false;
let isQuitting = false;

// Cache the latest capabilities/status/merged-state so a window that loads (or
// reloads) after they were first sent still gets the full picture — capabilities
// is only emitted once per connect, and would otherwise be lost on a reload.
let lastCaps: SidecarEvent | null = null;
let lastStatus: SidecarEvent | null = null;
let mergedState: GrillState = {};

function replayTo(wc: Electron.WebContents): void {
  if (lastCaps) wc.send(IPC.event, lastCaps);
  if (lastStatus) wc.send(IPC.event, lastStatus);
  if (Object.keys(mergedState).length) wc.send(IPC.event, { type: 'state', data: mergedState });
  sendShutdown(wc);
}

// --- graceful shutdown orchestration ---------------------------------------
// Owned by main so it survives the window being closed/hidden mid-cool-down.
let shutdownPhase: ShutdownPhase = null;
let shutdownCoolFrom = 0;
let shutdownStartedAt = 0;
let shutdownWarned = false;

function shutInput() {
  return {
    moduleIsOn: !!mergedState.moduleIsOn,
    grillTemp: typeof mergedState.grillTemp === 'number' ? mergedState.grillTemp : null,
    grillSetTemp: typeof mergedState.grillSetTemp === 'number' ? mergedState.grillSetTemp : null,
    fanState: !!mergedState.fanState,
  };
}

function sendShutdown(wc?: Electron.WebContents): void {
  (wc ?? win?.webContents)?.send(IPC.event, {
    type: 'shutdown', phase: shutdownPhase, coolFrom: shutdownCoolFrom, coolTarget: SHUTDOWN.coolTarget,
  });
}

function requestShutdown(mode: ShutdownMode): void {
  if (mode === 'cancel') {
    if (shutdownPhase) { shutdownPhase = null; sendShutdown(); log('shutdown cancelled'); }
    return;
  }
  if (mode === 'now' || shutdownPhase) {
    shutdownPhase = null;
    sidecar?.request({ cmd: 'off' }).catch(() => { /* surfaced in UI */ });
    notify('Shutting down now', 'Turning the grill off.');
    sendShutdown();
    return;
  }
  // mode === 'auto'
  const step = beginShutdown(shutInput());
  shutdownPhase = step.phase;
  shutdownStartedAt = Date.now();
  shutdownWarned = false;
  shutdownCoolFrom = typeof mergedState.grillTemp === 'number' ? mergedState.grillTemp : SHUTDOWN.coolTarget;
  if (step.action === 'cool') sidecar?.request({ cmd: 'set_temp', value: SHUTDOWN.coolTarget }).catch(() => {});
  if (step.action === 'off') sidecar?.request({ cmd: 'off' }).catch(() => {});
  if (step.notice) notify(step.notice.title, step.notice.body);
  sendShutdown();
}

// Advance the shutdown machine on each fresh grill state.
function driveShutdown(): void {
  if (!shutdownPhase) return;
  const step = advanceShutdown(shutdownPhase, shutInput());
  if (step.action === 'off') sidecar?.request({ cmd: 'off' }).catch(() => {});
  if (step.notice) notify(step.notice.title, step.notice.body);
  if (step.phase !== shutdownPhase) { shutdownPhase = step.phase; sendShutdown(); }
  else if (shutdownPhase === 'cooling') sendShutdown();  // push progress
  if (shutdownPhase && Date.now() - shutdownStartedAt > SHUTDOWN.stallMs && !shutdownWarned) {
    shutdownWarned = true;
    notify('Shutdown taking a while', "The cool-down hasn't finished — check the grill.");
  }
}

/** Show the window (creating/un-hiding it), or hide it if already up front. */
function toggleWindow(): void {
  if (!win) { createWindow(); return; }
  if (win.isVisible() && win.isFocused()) win.hide();
  else { win.show(); win.focus(); }
}

function createWindow(): void {
  const bounds = store?.get().windowBounds;
  win = new BrowserWindow({
    width: bounds?.width ?? 600,
    height: bounds?.height ?? 860,
    x: bounds?.x,
    y: bounds?.y,
    minWidth: 560,
    minHeight: 640,
    maxWidth: 820,
    title: 'Pit Boss',
    icon: ICON_PATH,           // window/taskbar icon (Windows/Linux)
    backgroundColor: '#16110d',
    webPreferences: {
      preload: path.join(__dirname, '..', 'preload', 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });

  attachRendererConsole(win.webContents);
  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));

  // Replay the current capabilities/status/state to the (re)loaded window so it
  // rebuilds its controls and readouts even if it missed the one-shot events.
  win.webContents.on('did-finish-load', () => {
    if (win) replayTo(win.webContents);
  });

  // Dev affordance: PITBOSS_SHOT=<path> dumps a PNG of the rendered UI once
  // loaded (no Screen Recording permission needed — it's our own page).
  const shot = process.env.PITBOSS_SHOT;
  if (shot) {
    win.webContents.once('did-finish-load', () => {
      setTimeout(async () => {
        try {
          const img = await win!.webContents.capturePage();
          fs.writeFileSync(shot, img.toPNG());
          log(`captured UI screenshot -> ${shot}`);
        } catch (e) {
          log('screenshot failed:', (e as Error).message);
        }
      }, 1500);
    });
  }

  // Persist geometry so the window reopens where the user left it.
  const saveBounds = () => {
    if (!win) return;
    const b = win.getBounds();
    store?.set({ windowBounds: { x: b.x, y: b.y, width: b.width, height: b.height } });
  };
  win.on('resize', saveBounds);
  win.on('move', saveBounds);

  // Menu-bar app behavior: closing the window just hides it (the grill keeps
  // being monitored in the tray); only an explicit Quit tears things down.
  win.on('close', (e) => {
    if (!isQuitting) { e.preventDefault(); win?.hide(); }
  });
  win.on('closed', () => { win = null; });

  if (process.argv.includes('--dev')) {
    win.webContents.openDevTools({ mode: 'detach' });
  }
}

function startSidecar(): void {
  // In a packaged build the Python venv + sidecar are bundled as extra
  // resources (see package.json build.extraResources); point the sidecar at
  // them. Unpackaged dev runs use the project's .venv via PROJECT_ROOT.
  let root = PROJECT_ROOT;
  if (app.isPackaged) {
    const res = process.resourcesPath;
    process.env.PITBOSS_PYTHON ||= path.join(res, 'pyenv', 'bin', 'python');
    process.env.PITBOSS_SIDECAR ||= path.join(res, 'python', 'sidecar.py');
    root = res;
  }
  sidecar = new Sidecar(root);

  // Forward every sidecar event to the renderer, and feed the recorder + tray
  // so charting, alerts, and the menu-bar readout work even with no window open.
  sidecar.on('event', (evt: SidecarEvent) => {
    if (evt.type === 'state') {
      mergedState = { ...mergedState, ...evt.data };
      recorder?.observe(evt.data);
      driveShutdown();
      tray?.setState(evt.data);
    } else if (evt.type === 'capabilities') {
      lastCaps = evt;
    } else if (evt.type === 'status') {
      lastStatus = evt;
      if (evt.device) recorder?.setDevice(evt.device);
      tray?.setConn(evt.connected, evt.connecting, evt.device);
      // Desktop notification when the grill comes online (edge-triggered).
      if (evt.connected && !wasConnected) {
        notify('Pit Boss Grill is online', `Connected to ${evt.device || 'your grill'}.`);
      }
      wasConnected = evt.connected;
    }
    win?.webContents.send(IPC.event, evt);
  });

  sidecar.start();
}

function notify(title: string, body: string): void {
  win?.webContents.send(IPC.event, { type: 'notice', title, body, level: 'info' });
  if (!Notification.isSupported()) return;
  try { new Notification({ title, body }).show(); }
  catch (e) { log('notification failed:', (e as Error).message); }
}

app.whenReady().then(() => {
  initLogging();
  log('app ready');
  // Dock icon for unpackaged dev runs on macOS (packaged builds get it from the
  // bundle's icon.icns, and ICON_PATH would point inside the asar).
  if (process.platform === 'darwin' && app.dock && !app.isPackaged) {
    try { app.dock.setIcon(ICON_PATH); } catch { /* non-fatal */ }
  }
  store = new SettingsStore();
  recorder = new Recorder(store);
  // Relay the recorder's notifications into the renderer's status bar.
  recorder.onNotice = (title, body, level) =>
    win?.webContents.send(IPC.event, { type: 'notice', title, body, level });
  tray = new TrayManager(TRAY_ICON, {
    toggleWindow,
    turnOff: () => requestShutdown('auto'),
  });
  tray.init();
  startSidecar();
  createWindow();

  // Renderer issues commands here; we relay to the sidecar and return its ack.
  ipcMain.handle(IPC.command, async (_e, cmd: GrillCommand) => {
    if (!sidecar) throw new Error('sidecar not running');
    return sidecar.request(cmd);
  });

  // Settings get/set.
  ipcMain.handle(IPC.getSettings, () => store!.get());
  ipcMain.handle(IPC.setSettings, (_e, patch: Partial<Settings>) => store!.set(patch));

  // Cook history queries.
  ipcMain.handle(IPC.history, () => recorder!.history());
  ipcMain.handle(IPC.listCooks, () => recorder!.listCooks());
  ipcMain.handle(IPC.readCook, (_e, id: string) => recorder!.readCook(id));
  ipcMain.handle(IPC.shutdown, (_e, mode: ShutdownMode) => { requestShutdown(mode); });

  app.on('activate', () => {
    // Dock/Tray click: recreate the window if gone, otherwise un-hide it.
    if (!win) createWindow();
    else { win.show(); win.focus(); }
  });
});

app.on('window-all-closed', () => {
  if (process.platform !== 'darwin') app.quit();
});

app.on('before-quit', () => {
  log('quitting; stopping sidecar');
  isQuitting = true;
  recorder?.dispose();
  store?.flush();
  tray?.destroy();
  sidecar?.stop();
});
