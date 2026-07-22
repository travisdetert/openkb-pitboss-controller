import { app, BrowserWindow, ipcMain, Menu, Notification, shell } from 'electron';
import * as fs from 'fs';
import * as path from 'path';
import { initLogging, attachRendererConsole, log } from './log';
import { Sidecar } from './sidecar';
import { SettingsStore } from './store';
import { Recorder } from './recorder';
import { TrayManager } from './tray';
import { advanceShutdown, beginShutdown, SHUTDOWN, ShutdownPhase } from './shutdown';
import { maintenanceDue, maintenanceReasons } from './maintenance';
import { resolveConfig } from './config';
import { GrillCommand, GrillState, IPC, NoticeLevel, Settings, ShutdownMode, SidecarEvent } from '../shared/protocol';

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
  if (recorder) {
    const m = recorder.maintenance();
    wc.send(IPC.event, { type: 'maintenance', state: m, due: maintenanceDue(m), reasons: maintenanceReasons(m) });
  }
}

// --- graceful shutdown orchestration ---------------------------------------
// Owned by main so it survives the window being closed/hidden mid-cool-down.
let shutdownPhase: ShutdownPhase = null;
let shutdownCoolFrom = 0;
let shutdownCoolTarget = SHUTDOWN.coolTarget;
let shutdownStartedAt = 0;
let shutdownWarned = false;

const shutdownCfg = () => resolveConfig(store?.get() ?? {}).shutdown;

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
    type: 'shutdown', phase: shutdownPhase, coolFrom: shutdownCoolFrom, coolTarget: shutdownCoolTarget,
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
  const cfg = shutdownCfg();
  const step = beginShutdown(shutInput(), cfg);
  shutdownPhase = step.phase;
  shutdownStartedAt = Date.now();
  shutdownWarned = false;
  shutdownCoolTarget = cfg.coolTarget;
  shutdownCoolFrom = typeof mergedState.grillTemp === 'number' ? mergedState.grillTemp : cfg.coolTarget;
  if (step.action === 'cool') sidecar?.request({ cmd: 'set_temp', value: cfg.coolTarget }).catch(() => {});
  if (step.action === 'off') sidecar?.request({ cmd: 'off' }).catch(() => {});
  if (step.notice) notify(step.notice.title, step.notice.body);
  sendShutdown();
}

// Advance the shutdown machine on each fresh grill state.
function driveShutdown(): void {
  if (!shutdownPhase) return;
  const cfg = shutdownCfg();
  const step = advanceShutdown(shutdownPhase, shutInput(), cfg);
  if (step.action === 'off') sidecar?.request({ cmd: 'off' }).catch(() => {});
  if (step.notice) notify(step.notice.title, step.notice.body);
  if (step.phase !== shutdownPhase) { shutdownPhase = step.phase; sendShutdown(); }
  else if (shutdownPhase === 'cooling') sendShutdown();  // push progress
  if (shutdownPhase && Date.now() - shutdownStartedAt > cfg.stallMs && !shutdownWarned) {
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
  // loaded (no Screen Recording permission needed — it's our own page). Env knobs:
  //   PITBOSS_SHOT_WAIT=live  — wait for live grill data before capturing (so the
  //                             shot shows a real running cook, not the wait screen)
  //   PITBOSS_SHOT_SETTLE=ms  — after data arrives, let the chart fill in (default 4s)
  //   PITBOSS_SHOT_MAXWAIT=ms — give up waiting for data and capture anyway (default 60s)
  //   PITBOSS_SHOT_DELAY=ms   — fixed delay when not waiting for live (default 1.5s)
  const shot = process.env.PITBOSS_SHOT;
  if (shot) {
    const capture = async () => {
      try {
        const img = await win!.webContents.capturePage();
        fs.writeFileSync(shot, img.toPNG());
        log(`captured UI screenshot -> ${shot}`);
      } catch (e) {
        log('screenshot failed:', (e as Error).message);
      }
    };
    win.webContents.once('did-finish-load', () => {
      if (process.env.PITBOSS_SHOT_WAIT === 'live') {
        const settle = Number(process.env.PITBOSS_SHOT_SETTLE) || 4000;
        const maxWait = Number(process.env.PITBOSS_SHOT_MAXWAIT) || 60_000;
        const started = Date.now();
        const tick = setInterval(() => {
          const live = typeof mergedState.grillTemp === 'number';
          const timedOut = Date.now() - started > maxWait;
          if (live || timedOut) {
            clearInterval(tick);
            log(live ? `shot: live data present, settling ${settle}ms…` : 'shot: max wait reached, capturing anyway');
            setTimeout(capture, live ? settle : 0);
          }
        }, 1000);
      } else {
        setTimeout(capture, Number(process.env.PITBOSS_SHOT_DELAY) || 1500);
      }
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
      tray?.setLabels(store?.get().probeLabels);
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

/** Bring the window to the front (creating it if needed) — used on notification
 * click and from the dock/tray menus. */
function showWindow(): void {
  if (!win) { createWindow(); return; }
  if (win.isMinimized()) win.restore();
  win.show();
  win.focus();
}

// Single, enriched notification path used by both main and the recorder. Alerts
// play a sound, stay on screen until dismissed, and bounce the dock; every
// notice is logged and relayed to the in-app status bar + banner.
function notify(title: string, body: string, level: NoticeLevel = 'info'): void {
  log(`notify: ${title} — ${body}`);
  win?.webContents.send(IPC.event, { type: 'notice', title, body, level });

  const alert = level === 'alert';
  if (process.platform === 'darwin' && app.dock) {
    try { app.dock.bounce(alert ? 'critical' : 'informational'); } catch { /* non-fatal */ }
  }
  if (Notification.isSupported()) {
    try {
      const n = new Notification({ title, body, silent: !alert, timeoutType: alert ? 'never' : 'default' });
      n.on('click', () => showWindow());       // clicking the banner focuses the app
      n.show();
    } catch (e) {
      log('notification failed:', (e as Error).message);
    }
  }
  if (alert) { try { shell.beep(); } catch { /* non-fatal */ } }
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
  // Route the recorder's notifications through the enriched OS-notification path.
  recorder.onNotice = (title, body, level) => notify(title, body, level);
  // Relay maintenance counters so the renderer can show the cleaning reminder.
  recorder.onMaintenance = (state, due, reasons) =>
    win?.webContents.send(IPC.event, { type: 'maintenance', state, due, reasons });
  tray = new TrayManager(TRAY_ICON, {
    toggleWindow,
    turnOff: () => requestShutdown('auto'),
  });
  tray.init();

  // Dock right-click menu (macOS): the same quick actions as the tray.
  if (process.platform === 'darwin' && app.dock) {
    app.dock.setMenu(Menu.buildFromTemplate([
      { label: 'Open Pit Boss', click: () => showWindow() },
      { label: 'Turn Off Grill', click: () => requestShutdown('auto') },
    ]));
  }

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
  ipcMain.handle(IPC.deleteCook, (_e, id: string) => recorder!.deleteCook(id));
  ipcMain.handle(IPC.renameCook, (_e, id: string, name: string) => recorder!.renameCook(id, name));
  ipcMain.handle(IPC.shutdown, (_e, mode: ShutdownMode) => { requestShutdown(mode); });
  ipcMain.handle(IPC.cleaned, () => { recorder!.resetMaintenance(); });

  // Start-at-login is OS-owned — read/write it straight from the OS, never a
  // shadow copy in settings.json.
  ipcMain.handle(IPC.getLoginItem, () => app.getLoginItemSettings().openAtLogin);
  ipcMain.handle(IPC.setLoginItem, (_e, open: boolean) => {
    app.setLoginItemSettings({ openAtLogin: !!open });
    return app.getLoginItemSettings().openAtLogin;
  });

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
