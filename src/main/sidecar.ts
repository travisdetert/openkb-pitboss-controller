// Manages the Python sidecar subprocess: spawns it, parses its line-delimited
// JSON output, matches command acks to pending requests, and re-emits pushed
// events (state/status/capabilities/scan_result).

import { spawn, ChildProcessWithoutNullStreams } from 'child_process';
import { EventEmitter } from 'events';
import * as fs from 'fs';
import * as path from 'path';
import * as readline from 'readline';
import { GrillCommand, SidecarEvent } from '../shared/protocol';
import { log } from './log';

export interface PendingRequest {
  resolve: (result: unknown) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

export class Sidecar extends EventEmitter {
  private proc: ChildProcessWithoutNullStreams | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private readonly projectRoot: string;

  constructor(projectRoot: string) {
    super();
    this.projectRoot = projectRoot;
  }

  /** Resolve the venv python + sidecar script paths, with overrides via env. */
  private resolvePaths(): { python: string; script: string } {
    const venvPython = process.platform === 'win32'
      ? path.join(this.projectRoot, '.venv', 'Scripts', 'python.exe')
      : path.join(this.projectRoot, '.venv', 'bin', 'python');
    const python = process.env.PITBOSS_PYTHON
      || (fs.existsSync(venvPython) ? venvPython : 'python3');
    const script = process.env.PITBOSS_SIDECAR
      || path.join(this.projectRoot, 'python', 'sidecar.py');
    return { python, script };
  }

  start(): void {
    const { python, script } = this.resolvePaths();
    log(`spawning sidecar: ${python} ${script}`);

    this.proc = spawn(python, ['-u', script], {
      cwd: this.projectRoot,
      stdio: ['pipe', 'pipe', 'pipe'],
      env: { ...process.env, PYTHONUNBUFFERED: '1' },
    });

    const rl = readline.createInterface({ input: this.proc.stdout });
    rl.on('line', (line) => this.onLine(line));

    // Sidecar's stderr is human diagnostics — funnel into the unified log.
    this.proc.stderr.on('data', (buf: Buffer) => {
      process.stderr.write(`[py] ${buf.toString()}`);
    });

    this.proc.on('exit', (code, signal) => {
      log(`sidecar exited code=${code} signal=${signal}`);
      this.failAllPending(new Error(`sidecar exited (${code ?? signal})`));
      this.emit('event', {
        type: 'status', connected: false, connecting: false,
        reason: 'sidecar_exited',
      } as SidecarEvent);
      this.proc = null;
    });

    this.proc.on('error', (err) => {
      log('sidecar spawn error:', err.message);
      this.emit('event', {
        type: 'status', connected: false, connecting: false,
        reason: `spawn_error: ${err.message}`,
      } as SidecarEvent);
    });
  }

  private onLine(line: string): void {
    line = line.trim();
    if (!line) return;
    let evt: SidecarEvent;
    try {
      evt = JSON.parse(line);
    } catch {
      log('unparseable sidecar line:', line);
      return;
    }

    // Resolve pending requests on ack/error that carry an id.
    if ((evt.type === 'ack' || evt.type === 'error') && typeof evt.id === 'number') {
      const p = this.pending.get(evt.id);
      if (p) {
        clearTimeout(p.timer);
        this.pending.delete(evt.id);
        if (evt.type === 'ack') p.resolve(evt.result);
        else p.reject(new Error(evt.message));
      }
    }

    // Always re-emit so the UI sees status/state/etc. (scan_result resolves
    // its request below, but is also forwarded for completeness).
    this.emit('event', evt);
  }

  /** Send a command; resolves with the sidecar's ack result (or rejects). */
  request(cmd: GrillCommand, timeoutMs = 30000): Promise<unknown> {
    if (!this.proc) return Promise.reject(new Error('sidecar not running'));
    const id = this.nextId++;

    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`command '${cmd.cmd}' timed out`));
      }, timeoutMs);

      // scan / list_models return via their own event (scan_result / models)
      // rather than a plain ack — special-case them.
      if (cmd.cmd === 'scan') {
        const onEvent = (evt: SidecarEvent) => {
          if (evt.type === 'scan_result' && evt.id === id) {
            clearTimeout(timer);
            this.off('event', onEvent);
            resolve(evt.devices);
          }
        };
        this.on('event', onEvent);
      } else if (cmd.cmd === 'list_models') {
        const onEvent = (evt: SidecarEvent) => {
          if (evt.type === 'models' && evt.id === id) {
            clearTimeout(timer);
            this.off('event', onEvent);
            resolve(evt.models);
          }
        };
        this.on('event', onEvent);
      } else {
        this.pending.set(id, { resolve, reject, timer });
      }

      this.write({ id, ...cmd });
    });
  }

  private write(obj: object): void {
    this.proc?.stdin.write(JSON.stringify(obj) + '\n');
  }

  private failAllPending(err: Error): void {
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(err);
    }
    this.pending.clear();
  }

  stop(): void {
    if (this.proc) {
      try {
        this.proc.stdin.end();
      } catch { /* ignore */ }
      this.proc.kill();
      this.proc = null;
    }
  }
}
