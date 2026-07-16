// Unit test for the settings -> thresholds resolver (src/main/config.ts).
// Run after a build:  node scripts/test-config.mjs

import { resolveConfig } from '../dist/main/config.js';
import { THERMAL } from '../dist/main/thermal.js';
import { MAINTENANCE } from '../dist/main/maintenance.js';
import { SHUTDOWN } from '../dist/main/shutdown.js';

let failures = 0;
function check(name, cond) {
  if (cond) console.log(`  ok   ${name}`);
  else { console.log(`  FAIL ${name}`); failures++; }
}

// --- defaults (empty settings) match the engine defaults --------------------
{
  const c = resolveConfig({});
  check('default door rate = THERMAL', c.thermal.doorRate === THERMAL.doorRate);
  check('default flare margin = MAINTENANCE', c.maintenance.flareMargin === MAINTENANCE.flareMargin);
  check('default cool target = SHUTDOWN', c.shutdown.coolTarget === SHUTDOWN.coolTarget);
  check('default cooks = MAINTENANCE', c.maintenance.afterCooks === MAINTENANCE.afterCooks);
}

// --- sensitivity scales detection ------------------------------------------
{
  const relaxed = resolveConfig({ detectionSensitivity: 'relaxed' });
  const sensitive = resolveConfig({ detectionSensitivity: 'sensitive' });
  check('relaxed needs a bigger drop', relaxed.thermal.doorRate > THERMAL.doorRate);
  check('sensitive trips earlier', sensitive.thermal.doorRate < THERMAL.doorRate);
  check('relaxed flare margin higher', relaxed.maintenance.flareMargin > MAINTENANCE.flareMargin);
  check('sensitive flare margin lower', sensitive.maintenance.flareMargin < MAINTENANCE.flareMargin);
}

// --- user maintenance thresholds passthrough (clamped) ----------------------
{
  const c = resolveConfig({ maintenanceThresholds: { afterCooks: 8, afterHours: 40, afterFlareups: 2 } });
  check('user cooks applied', c.maintenance.afterCooks === 8);
  check('user hours applied', c.maintenance.afterHours === 40);
  const clamped = resolveConfig({ maintenanceThresholds: { afterCooks: 9999, afterHours: 1, afterFlareups: 1 } });
  check('cooks clamped to <=100', clamped.maintenance.afterCooks === 100);
}

// --- shutdown config: coolDoneAt derives, coolAbove stays above target ------
{
  const c = resolveConfig({ shutdownConfig: { coolAbove: 300, coolTarget: 225 } });
  check('cool target applied', c.shutdown.coolTarget === 225);
  check('coolDoneAt = target + 10', c.shutdown.coolDoneAt === 235);
  check('coolAbove applied', c.shutdown.coolAbove === 300);
  // coolAbove below target -> clamped up above target
  const bad = resolveConfig({ shutdownConfig: { coolAbove: 100, coolTarget: 225 } });
  check('coolAbove clamped above target', bad.shutdown.coolAbove >= 235);
}

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
