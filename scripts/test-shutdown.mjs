// Unit test for the graceful-shutdown state machine (src/main/shutdown.ts).
// Run after a build:  node scripts/test-shutdown.mjs

import { beginShutdown, advanceShutdown, coolProgress, SHUTDOWN } from '../dist/main/shutdown.js';

let failures = 0;
function check(name, cond) {
  if (cond) console.log(`  ok   ${name}`);
  else { console.log(`  FAIL ${name}`); failures++; }
}

// --- begin: hot grill ramps down first --------------------------------------
{
  const s = beginShutdown({ moduleIsOn: true, grillTemp: 450, grillSetTemp: 450, fanState: true });
  check('begin hot -> cooling', s.phase === 'cooling');
  check('begin hot -> action cool', s.action === 'cool');
  check('begin hot -> has notice', !!s.notice);
}

// --- begin: already-cool grill powers off immediately -----------------------
{
  const s = beginShutdown({ moduleIsOn: true, grillTemp: 190, grillSetTemp: 225, fanState: true });
  check('begin cool -> finishing', s.phase === 'finishing');
  check('begin cool -> action off', s.action === 'off');
}

// --- begin: grill off -> off path -------------------------------------------
{
  const s = beginShutdown({ moduleIsOn: false, grillTemp: null, grillSetTemp: null, fanState: false });
  check('begin off -> action off', s.action === 'off');
}

// --- advance cooling: still hot -> stay cooling -----------------------------
{
  const s = advanceShutdown('cooling', { moduleIsOn: true, grillTemp: 300, grillSetTemp: 200, fanState: true });
  check('cooling@300 -> stay cooling', s.phase === 'cooling' && s.action === null);
}

// --- advance cooling: reached cool target -> off ----------------------------
{
  const s = advanceShutdown('cooling', { moduleIsOn: true, grillTemp: 205, grillSetTemp: 200, fanState: true });
  check('cooling@205 -> finishing', s.phase === 'finishing');
  check('cooling@205 -> action off', s.action === 'off');
}

// --- advance finishing: fan still running -> stay ---------------------------
{
  const s = advanceShutdown('finishing', { moduleIsOn: false, grillTemp: 180, grillSetTemp: 200, fanState: true });
  check('finishing + fan on -> stay', s.phase === 'finishing' && s.action === null);
}

// --- advance finishing: fully off -> done -----------------------------------
{
  const s = advanceShutdown('finishing', { moduleIsOn: false, grillTemp: 120, grillSetTemp: 200, fanState: false });
  check('finishing + fully off -> done', s.phase === null && s.action === null && s.notice === null);
}

// --- cool progress ----------------------------------------------------------
{
  check('progress start ~0', coolProgress(450, 450) === 0);
  check('progress midway ~0.5', Math.abs(coolProgress(400, 300) - 0.5) < 0.01); // (400-300)/(400-200)
  check('progress done clamps to 1', coolProgress(400, 200) === 1);
  check('progress below target clamps to 1', coolProgress(400, 180) === 1);
}

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
