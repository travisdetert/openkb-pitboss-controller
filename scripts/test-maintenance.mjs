// Unit test for the maintenance logic (src/main/maintenance.ts).
// Run after a build:  node scripts/test-maintenance.mjs

import {
  freshMaintenance, maintenanceReasons, maintenanceDue, isFlareup, MAINTENANCE,
} from '../dist/main/maintenance.js';

let failures = 0;
function check(name, cond) {
  if (cond) console.log(`  ok   ${name}`);
  else { console.log(`  FAIL ${name}`); failures++; }
}

// --- fresh state is not due -------------------------------------------------
{
  const m = freshMaintenance();
  check('fresh not due', maintenanceDue(m) === false);
  check('fresh reasons empty', maintenanceReasons(m).length === 0);
}

// --- due by cooks -----------------------------------------------------------
{
  const m = { ...freshMaintenance(), cooksSinceClean: MAINTENANCE.afterCooks };
  check('due by cooks', maintenanceDue(m) === true);
  check('reason names cooks', maintenanceReasons(m).some((r) => r.includes('cook')));
}

// --- due by run-hours -------------------------------------------------------
{
  const m = { ...freshMaintenance(), runSecondsSinceClean: MAINTENANCE.afterHours * 3600 };
  check('due by hours', maintenanceDue(m) === true);
  check('reason names hours', maintenanceReasons(m).some((r) => r.includes('h of use')));
}

// --- due by flare-ups -------------------------------------------------------
{
  const m = { ...freshMaintenance(), flareupsSinceClean: MAINTENANCE.afterFlareups };
  check('due by flare-ups', maintenanceDue(m) === true);
  check('reason names flare-ups', maintenanceReasons(m).some((r) => r.includes('flare-up')));
}

// --- just under thresholds is not due --------------------------------------
{
  const m = {
    cooksSinceClean: MAINTENANCE.afterCooks - 1,
    runSecondsSinceClean: (MAINTENANCE.afterHours - 1) * 3600,
    flareupsSinceClean: MAINTENANCE.afterFlareups - 1,
    cleanedAt: 0,
  };
  check('under thresholds not due', maintenanceDue(m) === false);
}

// --- flare-up detection -----------------------------------------------------
{
  check('flare: temp >> setpoint & on', isFlareup(400, 250, true) === true); // 150 over
  check('flare: within margin -> no', isFlareup(300, 250, true) === false);  // 50 over
  check('flare: grill off -> no', isFlareup(400, 250, false) === false);
  check('flare: missing temp -> no', isFlareup(null, 250, true) === false);
}

console.log(failures === 0 ? '\nALL PASS' : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
