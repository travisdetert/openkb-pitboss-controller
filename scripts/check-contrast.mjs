// WCAG AA contrast for the desktop theme tokens, in both themes.
//
// The sibling of ios/Tools/check-contrast.py. An app that ships two themes has
// to be legible in both — designing dark-first and letting light fall out
// broken is the usual failure, so this checks each palette independently and
// fails the build rather than leaving it to be noticed in a screenshot.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const css = fs.readFileSync(path.join(ROOT, 'src/renderer/styles.css'), 'utf8');

// Pull a token block: the dark defaults from the first :root, the light values
// from the explicit [data-theme="light"] block (identical to the media query's,
// which is why only one of the two is read).
function tokens(selector) {
  const i = css.indexOf(selector);
  if (i < 0) throw new Error(`no ${selector} block in styles.css`);
  const body = css.slice(css.indexOf('{', i) + 1, css.indexOf('}', i));
  const out = {};
  for (const m of body.matchAll(/--([\w-]+):\s*(#[0-9a-fA-F]{6})\s*;/g)) out[m[1]] = m[2];
  return out;
}

const lum = (hex) => {
  const v = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255)
    .map((c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4));
  return 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2];
};
const ratio = (a, b) => {
  const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
};

const BACKGROUNDS = ['bg', 'bg-card', 'bg-card2'];
const FOREGROUNDS = ['text', 'muted', 'flame', 'ok', 'warn', 'danger', 'blue'];
const AA = 4.5;

let fail = 0, checks = 0;
for (const [name, sel] of [['dark', ':root {'], ['light', ':root[data-theme="light"]']]) {
  const t = tokens(sel);
  console.log(`\n${name}`);
  for (const fg of FOREGROUNDS) {
    for (const bg of BACKGROUNDS) {
      if (!t[fg] || !t[bg]) { console.log(`  MISSING ${fg} or ${bg}`); fail++; continue; }
      const r = ratio(t[fg], t[bg]);
      checks++;
      const good = r >= AA;
      if (!good) fail++;
      console.log(`  ${fg.padEnd(10)} on ${bg.padEnd(9)} ${r.toFixed(2).padStart(5)}  ${good ? 'OK' : 'FAIL'}`);
    }
  }
}

console.log(fail === 0
  ? `\n✓ every token meets WCAG AA (${AA}:1) in 2 themes — ${checks} pairs\n`
  : `\n✗ ${fail} contrast failure(s)\n`);
process.exit(fail === 0 ? 0 : 1);
