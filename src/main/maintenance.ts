// Cleaning/maintenance tracking — pure, dependency-free logic (unit-tested in
// scripts/test-maintenance.mjs). The recorder accumulates usage and flare-ups
// into a MaintenanceState; this module decides when a cleaning is due.
//
// Why flare-ups matter: a large temperature spike well above the setpoint often
// means a grease fire in the barrel. Repeated flare-ups mean grease has built up
// and it's time to clean the drip tray / grease bucket — a fire-safety issue.

export interface MaintenanceState {
  cooksSinceClean: number;
  runSecondsSinceClean: number;
  flareupsSinceClean: number;
  cleanedAt: number;            // epoch ms of last "Cleaned"
}

export interface MaintenanceThresholds {
  afterCooks: number;
  afterHours: number;
  afterFlareups: number;
  flareMargin: number;          // ° above setpoint that counts as a flare-up
}

export const MAINTENANCE: MaintenanceThresholds = {
  afterCooks: 5,
  afterHours: 30,
  afterFlareups: 3,
  flareMargin: 100,
};

export function freshMaintenance(): MaintenanceState {
  return { cooksSinceClean: 0, runSecondsSinceClean: 0, flareupsSinceClean: 0, cleanedAt: 0 };
}

// Human-readable reasons a cleaning is recommended (empty = not due yet).
export function maintenanceReasons(m: MaintenanceState, th: MaintenanceThresholds = MAINTENANCE): string[] {
  const reasons: string[] = [];
  if (m.cooksSinceClean >= th.afterCooks) reasons.push(`${m.cooksSinceClean} cooks`);
  const hours = m.runSecondsSinceClean / 3600;
  if (hours >= th.afterHours) reasons.push(`${Math.round(hours)}h of use`);
  if (m.flareupsSinceClean >= th.afterFlareups) reasons.push(`${m.flareupsSinceClean} flare-ups`);
  return reasons;
}

export function maintenanceDue(m: MaintenanceState, th: MaintenanceThresholds = MAINTENANCE): boolean {
  return maintenanceReasons(m, th).length > 0;
}

// A flare-up: the grill reads well above its setpoint while running (a possible
// grease fire). Judged only when both temps are known and the grill is on.
export function isFlareup(
  grillTemp: number | null, grillSetTemp: number | null, moduleIsOn: boolean,
  th: MaintenanceThresholds = MAINTENANCE,
): boolean {
  return moduleIsOn && typeof grillTemp === 'number' && typeof grillSetTemp === 'number'
    && grillTemp > grillSetTemp + th.flareMargin;
}
