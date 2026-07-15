// macOS menu-bar (Tray) presence: a flame icon showing the live grill temp,
// with a dropdown for status, probes, and quick controls. This is what makes
// the grill feel like an ambient appliance instead of an app you go open.

import { Tray, Menu, nativeImage, MenuItemConstructorOptions } from 'electron';
import { GrillState } from '../shared/protocol';
import { log } from './log';

export interface TrayCallbacks {
  toggleWindow: () => void;
  turnOff: () => void;
}

export class TrayManager {
  private tray: Tray | null = null;
  private state: GrillState = {};
  private connected = false;
  private connecting = false;
  private device?: string;

  constructor(private readonly iconPath: string, private readonly cb: TrayCallbacks) {}

  init(): void {
    const img = nativeImage.createFromPath(this.iconPath);
    img.setTemplateImage(true);            // adapt to light/dark menu bar
    this.tray = new Tray(img);
    this.tray.on('click', () => this.cb.toggleWindow());
    this.refresh();
    log('tray initialized');
  }

  setState(s: GrillState): void {
    this.state = { ...this.state, ...s };
    this.refresh();
  }

  setConn(connected: boolean, connecting: boolean, device?: string): void {
    this.connected = connected;
    this.connecting = connecting;
    if (device) this.device = device;
    this.refresh();
  }

  private unit(): string {
    return this.state.isFahrenheit === false ? '°C' : '°F';
  }

  private statusLine(): string {
    if (this.connected) {
      const u = this.unit();
      const t = this.state.grillTemp != null ? `${this.state.grillTemp}${u}` : '--';
      const set = this.state.grillSetTemp != null ? ` → ${this.state.grillSetTemp}${u}` : '';
      return `Grill ${t}${set}`;
    }
    return this.connecting ? 'Connecting…' : 'Disconnected';
  }

  private refresh(): void {
    if (!this.tray) return;
    const u = this.unit();

    // Live temp right in the menu bar when connected — the ambient readout.
    this.tray.setTitle(
      this.connected && this.state.grillTemp != null ? ` ${this.state.grillTemp}°` : '',
    );
    this.tray.setToolTip(`Pit Boss Grill — ${this.statusLine()}`);

    const probeItems: MenuItemConstructorOptions[] = [];
    for (let i = 1; i <= 4; i++) {
      const v = (this.state as Record<string, unknown>)[`p${i}Temp`];
      if (typeof v === 'number') {
        probeItems.push({ label: `Probe ${i}:  ${v}${u}`, enabled: false });
      }
    }

    const template: MenuItemConstructorOptions[] = [
      { label: this.statusLine(), enabled: false },
      ...(this.device ? [{ label: this.device, enabled: false } as MenuItemConstructorOptions] : []),
      ...(probeItems.length ? [{ type: 'separator' } as MenuItemConstructorOptions, ...probeItems] : []),
      { type: 'separator' },
      { label: 'Open Pit Boss', click: () => this.cb.toggleWindow() },
      { label: 'Turn Off Grill', enabled: this.connected, click: () => this.cb.turnOff() },
      { type: 'separator' },
      { label: 'Quit', role: 'quit' },
    ];
    this.tray.setContextMenu(Menu.buildFromTemplate(template));
  }

  destroy(): void {
    this.tray?.destroy();
    this.tray = null;
  }
}
