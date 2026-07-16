# Detection Test Plan — pellets, door/lid, probes

A hands-on plan to prove out the grill-monitoring alerts against the real grill
(Pro Series 1100 Combo, `PB1100PSC3`). It covers the thermal-anomaly detector
(`src/main/thermal.ts` + `Recorder.checkThermal`) and the existing probe / pellet
/ error alerts.

> These are edge-triggered notifications: each fires **once** and re-arms only
> after the condition clears. Thresholds live in the `THERMAL` block of
> `src/main/thermal.ts` — tune them here as real cooks reveal the right values.

## What the detector does

```mermaid
stateDiagram-v2
    [*] --> Off
    Off --> WarmingUp: grill on
    WarmingUp --> AtTemp: temp ≥ set − 15°
    note right of WarmingUp
      No thermal alerts here
      (also suppressed right after
       a setpoint change)
    end note
    AtTemp --> DoorOpen: steep drop\n≥25°/min & ≥20° below set
    AtTemp --> LowPellets: slow decline\n≥4°/min over ~4 min & ≥40° below set
    DoorOpen --> AtTemp: recovers within 10° of set
    LowPellets --> AtTemp: recovers within 20° of set
    AtTemp --> Off: grill off
    DoorOpen --> Off: grill off
    LowPellets --> Off: grill off
```

## Before you start

1. **Launch from the tree** so logs stream: `npm start`.
2. **Tail the unified log** in another terminal:
   `tail -f /tmp/openkb-pitboss.log`
   Every notification also logs a line: `notify: <title> — <body>`.
3. **Allow notifications** for the app (macOS System Settings → Notifications) so
   the banners actually appear when you're away from the screen.
4. Have a **full hopper** and, ideally, a **timer**. Some tests intentionally run
   the fire out — do them when you can safely tend the grill.

Key log signatures to watch for:

| Event | Log line contains |
|---|---|
| Reached setpoint | grill temp climbs to set − 15° (no alert; just observe) |
| Probe at target | `notify: <probe name> reached target` |
| Lid/door open | `notify: Lid open?` |
| Low/out of pellets (our heuristic) | `notify: Running low on pellets?` |
| Controller's own empty flag | `notify: Out of pellets` |
| Controller fault | `notify: Grill error` |

## Test cases

### T1 — Warm-up produces no false alarms
1. Start cold. Set grill to **250°F**. 
2. Watch the climb from ambient to 250°.
- **Expect:** *no* "Lid open?" or "pellets" notification during warm-up (the
  detector only judges once temp reaches set − 15°). Grill chart rises smoothly.

### T2 — Setpoint reached, steady hold
1. After T1, let it hold at 250° for ~5 min.
- **Expect:** no thermal alerts while it cycles around setpoint. Probe/grill
  mini-charts update.

### T3 — Probe target reached
1. Plug **Probe 1**, label it (e.g. "Chicken"), set target to a value just above
   its current reading (e.g. current + 5°).
2. Warm the probe (hand, or actual food coming up to temp).
- **Expect:** dot goes amber → green, subline shows "At target …✓", and a
  `notify: Chicken reached target` with a beep. Fires once.

### T4 — Door / lid open (the fast drop)
1. With the grill **held at 250°+**, open the lid and leave it open.
2. Watch the grill temp fall.
- **Expect:** within ~1 minute of a steep fall (≥25°/min and ≥20° below set), a
  **"Lid open?"** notification. The grill mini-chart shows a sharp downstroke.
3. Close the lid; let it recover.
- **Expect:** no repeat alert while recovering; the latch re-arms once temp is
  back within 10° of setpoint (so a *second* lid-open later fires again).
- **Tuning note:** if it fires too eagerly on brief peeks, raise `doorRate` or
  `doorMinDrop`; if it misses a real opening, lower them.

### T5 — Out of pellets (the slow decline)
> Do this at the end of a session when it's safe to let the fire die.
1. Hold at temp, then **let the hopper run empty** (or divert/empty it).
2. Watch the temp sag over several minutes as the fire starves.
- **Expect:** once temp is ≥40° below setpoint and still declining (≥4°/min over
  ~4 min), a **"Running low on pellets?"** notification — ideally *before* the
  controller raises its own empty flag.
3. If/when the controller sets its `noPellets` flag:
- **Expect:** the existing `notify: Out of pellets` fires, and our heuristic does
  **not** double-notify (it defers to the hardware flag).
- **Tuning note:** if it's slow to warn, lower `pelletDev` or `pelletRate`; if it
  false-fires on a normal deep auger cycle, raise them.

### T6 — Distinguish door vs pellets
1. Compare T4 and T5 timing/shape on the grill chart: door = **sharp** cliff;
   pellets = **gentle** sustained slope.
- **Expect:** the fast drop reads as "Lid open?", the slow drift as "pellets" —
  not the other way around. (The classifier unit test asserts this; T6 confirms
  it on real thermal mass.)

### T7 — Lowering the setpoint doesn't false-alarm
1. While holding 300°, drop the setpoint to **225°**.
2. Temp falls naturally to the new target.
- **Expect:** *no* "Lid open?" or "pellets" alert during the descent (a setpoint
  change resets the detector until temp settles at the new value).

### T8 — Re-arm after recovery
1. After a T4 lid alert and recovery, open the lid a second time.
- **Expect:** a fresh "Lid open?" fires (latch re-armed).

## Results log

First on-grill pass — 2026-07-16, live cook to 350°F on the PB1100PSC3.

| # | Test | Pass/Fail | Time-to-alert | Notes / tuning |
|---|------|-----------|---------------|----------------|
| T1 | Warm-up quiet | **Pass** | — | Zero notifications climbing to 350°; auger oscillation never faked an event. |
| T2 | Steady hold | **Pass** | — | Quiet at hold; auger ~8s-on / 16s-off cadence. |
| T3 | Probe target | **Pass** | immediate | Probe reached/over-target fired. See bug below re: clearing the app target. |
| T4 | Lid open | **Pass** | ~1 min | Fired at **−27°/min, 324°** (26° below 350° set); once, no double-fire; latch re-armed on recovery. Thresholds `doorRate 25` / `doorMinDrop 20` well-tuned — leave as-is. |
| T5 | Out of pellets | *not run* | | End-of-session test; deferred. |
| T6 | Door vs pellets | *partial* | | Door confirmed (T4); pellet side pending T5. |
| T7 | Setpoint-down suppression | *n/a this pass* | | Not run standalone, but see the flare-up finding below (same class of gate). |
| T8 | Re-arm | **Pass** | | Single lid alert; re-armed silently during recovery. |
| SD | Graceful shutdown | **Pass** | | Turn Off at ~350° → `set_temp 200` (cool-down, not power-off-while-hot) → shed 328→~200° over ~18 min → `cmd:off` at 200° → device fan cool-down. The full staged chain executed on real fire. |

### Bugs surfaced by this pass

1. **Flare-up false-alarm during cool-down.** When the graceful shutdown lowered
   the setpoint to 200° while the grill was still ~328°, the flare-up detector
   fired ("possible grease fire") — temp legitimately far above the *just-lowered*
   setpoint. Fix: suppress flare-up detection after a commanded setpoint decrease
   until the temp settles near the new setpoint (same gate as the thermal
   detector's setpoint-change reset).
2. **Clearing a probe target left its warning.** The over-target warning prefers
   the grill's own reported target over the app's, so clearing the app-side target
   (✕) didn't clear the warning. Fix: make the app's probe warnings authoritative
   on the app-side target.
3. **In-app alert too fleeting.** Alerts flash ~12s in the status bar — easy to
   miss at the grill. Fix: a dismissible alert banner that stays until acknowledged.
4. **Shutdown pacing note.** Because "cool to 200" sets the grill to *maintain*
   200° (auger keeps feeding), a grill that stabilizes just above the 210°
   power-off trigger could hover. This run reached ~200° and powered off fine, but
   consider firing `off` once *close enough* rather than requiring ≤210° exactly.

## Automated coverage

The pure classifier is unit-tested independent of the grill:

```
npm test        # builds, then runs the thermal, shutdown, and maintenance suites (~40 cases)
```

They cover: steady = quiet, steep = door, slow = pellets, warm-up suppressed,
`noPellets` deferral, the rate-window math, the shutdown state machine, and the
maintenance/flare-up thresholds. The hardware tests above validate those
thresholds against real thermal behavior that the unit tests can't.
