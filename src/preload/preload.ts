import { contextBridge, ipcRenderer } from 'electron';

// Self-contained on purpose: a sandboxed preload can't `require()` sibling
// compiled modules, so we inline the few constants/types we need rather than
// importing from ../shared/protocol.
const IPC = {
  command: 'pitboss:command',
  event: 'pitboss:event',
  getSettings: 'pitboss:settings:get',
  setSettings: 'pitboss:settings:set',
  history: 'pitboss:history',
  listCooks: 'pitboss:cooks:list',
  readCook: 'pitboss:cooks:read',
} as const;

type GrillCommand =
  | { cmd: 'connect'; name?: string; model?: string }
  | { cmd: 'disconnect' }
  | { cmd: 'scan'; seconds?: number }
  | { cmd: 'set_temp'; value: number }
  | { cmd: 'set_probe'; probe: number; value: number }
  | { cmd: 'light'; on: boolean }
  | { cmd: 'prime'; on: boolean }
  | { cmd: 'off' }
  | { cmd: 'refresh' };

function invoke(cmd: GrillCommand): Promise<unknown> {
  return ipcRenderer.invoke(IPC.command, cmd);
}

// The single, minimal API exposed to the renderer. No node, no IPC details.
const api = {
  connect: (name?: string, model?: string) => invoke({ cmd: 'connect', name, model }),
  disconnect: () => invoke({ cmd: 'disconnect' }),
  scan: (seconds = 8) => invoke({ cmd: 'scan', seconds }),
  setTemp: (value: number) => invoke({ cmd: 'set_temp', value }),
  setProbe: (probe: number, value: number) => invoke({ cmd: 'set_probe', probe, value }),
  light: (on: boolean) => invoke({ cmd: 'light', on }),
  prime: (on: boolean) => invoke({ cmd: 'prime', on }),
  off: () => invoke({ cmd: 'off' }),
  refresh: () => invoke({ cmd: 'refresh' }),

  // Persisted settings + cook history.
  getSettings: () => ipcRenderer.invoke(IPC.getSettings),
  setSettings: (patch: unknown) => ipcRenderer.invoke(IPC.setSettings, patch),
  getHistory: () => ipcRenderer.invoke(IPC.history),
  listCooks: () => ipcRenderer.invoke(IPC.listCooks),
  readCook: (id: string) => ipcRenderer.invoke(IPC.readCook, id),

  onEvent: (cb: (evt: unknown) => void) => {
    const listener = (_e: unknown, evt: unknown) => cb(evt);
    ipcRenderer.on(IPC.event, listener);
    return () => ipcRenderer.off(IPC.event, listener);
  },
};

contextBridge.exposeInMainWorld('pitboss', api);
