// Resolve user-adjustable settings into concrete engine thresholds. Kept pure
// and dependency-free so it can be unit-tested (scripts/test-config.mjs).
//
// The engines (thermal, maintenance, shutdown) all accept a thresholds object,
// so this is the single place that turns "Sensitive" or "cool to 225°" into the
// numbers they run on. Everything falls back to the built-in defaults.

import { THERMAL, ThermalThresholds } from './thermal';
import { MAINTENANCE, MaintenanceThresholds } from './maintenance';
import { SHUTDOWN } from './shutdown';
import { DetectionSensitivity, Settings } from '../shared/protocol';

export interface ResolvedConfig {
  thermal: ThermalThresholds;
  maintenance: MaintenanceThresholds;   // includes flareMargin
  shutdown: { coolAbove: number; coolTarget: number; coolDoneAt: number; stallMs: number };
}

// How each sensitivity scales the detection thresholds. >1 = needs a bigger
// signal (fewer alerts); <1 = trips earlier (more alerts).
const SCALE: Record<DetectionSensitivity, { rate: number; dev: number; flare: number }> = {
  relaxed:   { rate: 1.35, dev: 1.35, flare: 1.3 },
  standard:  { rate: 1.0,  dev: 1.0,  flare: 1.0 },
  sensitive: { rate: 0.7,  dev: 0.7,  flare: 0.8 },
};

const clampNum = (v: unknown, lo: number, hi: number, dflt: number): number =>
  typeof v === 'number' && isFinite(v) ? Math.max(lo, Math.min(hi, v)) : dflt;

export function resolveConfig(s: Partial<Settings> = {}): ResolvedConfig {
  const sens: DetectionSensitivity = s.detectionSensitivity ?? 'standard';
  const k = SCALE[sens] ?? SCALE.standard;

  const thermal: ThermalThresholds = {
    ...THERMAL,
    doorRate: Math.round(THERMAL.doorRate * k.rate),
    doorMinDrop: Math.round(THERMAL.doorMinDrop * k.dev),
    pelletRate: Math.round(THERMAL.pelletRate * k.rate * 10) / 10,
    pelletDev: Math.round(THERMAL.pelletDev * k.dev),
  };

  const mt = s.maintenanceThresholds;
  const maintenance: MaintenanceThresholds = {
    afterCooks: clampNum(mt?.afterCooks, 1, 100, MAINTENANCE.afterCooks),
    afterHours: clampNum(mt?.afterHours, 1, 500, MAINTENANCE.afterHours),
    afterFlareups: clampNum(mt?.afterFlareups, 1, 50, MAINTENANCE.afterFlareups),
    flareMargin: Math.round(MAINTENANCE.flareMargin * k.flare),
  };

  const sc = s.shutdownConfig;
  const coolTarget = clampNum(sc?.coolTarget, 150, 300, SHUTDOWN.coolTarget);
  const coolAbove = clampNum(sc?.coolAbove, coolTarget + 10, 500, SHUTDOWN.coolAbove);
  const shutdown = { coolAbove, coolTarget, coolDoneAt: coolTarget + 10, stallMs: SHUTDOWN.stallMs };

  return { thermal, maintenance, shutdown };
}
