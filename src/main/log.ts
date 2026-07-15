// Unified logging: tee main-process stdout/stderr to a fixed, tailable file,
// and forward renderer console messages into the same stream. So debugging
// never requires opening DevTools or copy/pasting errors.
//
//   tail -f /tmp/openkb-pitboss.log
//
// Follows the standard openkb Electron logging convention.

import * as fs from 'fs';
import { WebContents } from 'electron';

export const LOG_PATH = '/tmp/openkb-pitboss.log';

let stream: fs.WriteStream | null = null;

export function initLogging(): void {
  stream = fs.createWriteStream(LOG_PATH, { flags: 'a' });

  const stamp = () => new Date().toISOString();

  const wrap = (
    orig: (chunk: any, ...args: any[]) => boolean,
    tag: string,
  ) => {
    return (chunk: any, ...args: any[]): boolean => {
      try {
        stream?.write(`${stamp()} ${tag} ${chunk}`);
      } catch {
        /* never let logging break the app */
      }
      return orig(chunk, ...args);
    };
  };

  process.stdout.write = wrap(
    process.stdout.write.bind(process.stdout),
    '',
  ) as typeof process.stdout.write;
  process.stderr.write = wrap(
    process.stderr.write.bind(process.stderr),
    '[stderr]',
  ) as typeof process.stderr.write;

  log(`--- openkb-pitboss started, logging to ${LOG_PATH} ---`);
}

export function log(...args: unknown[]): void {
  console.log('[main]', ...args);
}

// Forward renderer console.* into the main log, tagged by level.
export function attachRendererConsole(wc: WebContents): void {
  wc.on('console-message', (_event, level, message, line, sourceId) => {
    const tag =
      level === 3 ? '[renderer error]' :
      level === 2 ? '[renderer warn]' :
      '[renderer]';
    const where = sourceId ? ` (${sourceId}:${line})` : '';
    console.log(`${tag} ${message}${where}`);
  });
}
