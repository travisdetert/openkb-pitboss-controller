<!--
  PROJECT.md — the project charter. One scannable file that answers
  "what is this, and how do we know when it's done?"
  Keep it short. Update Status / Now / Next as work lands.
  Status values: Idea · Building · Usable · Done · Parked
-->
# openkb-pit-boss — Charter

**Status:** Done
**Updated:** 2026-09-18

## Goal
A local, account-free app to control a Pit Boss pellet grill over
Bluetooth — on the desktop, and now natively on iPhone/iPad (ADR 0006). It talks directly to the grill's Mongoose-OS / PBL control board via
BLE (reusing the `pytboss` library through a Python sidecar) and exposes the
controls you actually own — set grill temp, set meat-probe targets, lights,
prime, on/off — plus cook recording and native alerts (probe-at-target, out of
pellets, controller error). No Dansons cloud, no account, no telemetry. For the
owner of a Pit Boss grill (built and verified against a Pro Series 1100 Combo,
`PB1100PSC3`, PBL board, firmware 0.5.7) who wants a fast, private,
walk-away-and-get-notified control surface on the desktop.

## Definition of Done
v1 is done when all of these are true.
- [x] Connects to the grill over BLE by stable advertised name and reads live state
- [x] Core controls work end-to-end: set temp, set probe target, lights, prime, off
- [x] Cook recorder + native notifications (probe target, pellets, errors)
- [x] Unified, tailable main+renderer log (`/tmp/openkb-pit-boss.log`)
- [x] Packaged app is self-contained: sidecar frozen to a standalone binary (no
  system Python/venv) — verified no external refs + runs from the bundle (ADR 0005).
  Bundle 357M → 288M. (A full on-a-clean-Mac BLE smoke test is still ideal.)
- [ ] Bluetooth permission UX is graceful: clear prompt + guidance when denied
- [x] Auto-reconnect proven across real BLE drops (short antenna range) — iOS
  recovers a dropped link in **8–17s with no user action**, verified on the grill
  at -95 dBm (2026-09-19). The system holds the reconnect, so it completes with
  the app suspended; see `ios/README.md` → Staying connected
- [ ] Runs/builds from a fresh checkout (README documents how) — incl. icon build
- [x] Security pass run; findings fixed or accepted (SECURITY.md — 2026-07-19)
- [x] Data storage & backup decided: data in `userData` (not the repo), app name
  pinned, local-only backup accepted for a grill controller (ADR 0004)
- [x] Notable decisions recorded (docs/adr/ — 0001 process, 0002 graceful
  shutdown, 0003 grill discovery & model selection, 0004 local-only storage,
  0005 frozen sidecar binary)
- [x] Works for anyone: first-run wizard scans, finds the grill, and picks the
  model (any Bluetooth Pit Boss grill, not just the dev's PB1100PSC3)

Beyond the original v1 bar, the app grew a monitoring + fire-safety suite (see
`docs/session-review.html` and `docs/detection-test-plan.md`):
- [x] Per-source panels: grill + each probe with its own chart; component-activity
  timeline (auger/fan/igniter); custom probe labels saved into each cook
- [x] Estimated pellet level from auger run-time (refill/emptied resets)
- [x] Anomaly detection: lid-open vs. out-of-pellets, over-temp, grease-fire flare-up
- [x] Graceful shutdown (cool-to-200 → off → device cool-down) — prevents the
  hopper burnback that motivated this project; **validated on the grill 2026-07-16**
- [x] Maintenance cycles (cooks / run-hours / flare-ups) with cleaning reminders
- [x] In-app status bar with the grill lifecycle + relayed notifications
- [x] Prominent header **session clock** — ticking elapsed time of the live cook
  (flame-lit when running), or a past cook's total length when one is selected
- [x] Cooking knowledge base shared by both apps from one file (ADR 0007):
  45 cuts, 7 named methods, USDA floors — with drift guards in `npm test`
- [x] Stall-aware cook estimates on both apps, from one algorithm held to shared
  golden vectors (`data/estimate-vectors.json`)
- [x] Desktop UI supports **both themes**, OS-following with an override, every
  colour from the token layer (canvas included), AA-verified in `npm test`
- [x] Desktop screenshots are reproducible: `npm run screenshots` drives the real
  app against a committed replay fixture, no grill attached

## Now / Next
- **Now: both apps carry the same cooking knowledge (ADR 0007, implemented).**
  `data/cooking.json` is the one source of truth for 45 cuts, 7 methods and the
  USDA floors; `data/estimate-vectors.json` is the one definition of what the
  cook-time estimator does. iOS and the desktop each read both, and `npm test`
  fails if a vendored copy drifts or if the two estimators disagree. The guard
  was itself verified by poisoning a vector and confirming *both* harnesses
  failed on the same assertion.
  The desktop gained: the cut picker (two screens — choosing a cut shows that
  cut and nothing else), named methods with stage tracking, per-probe ETAs that
  declare their stall and pellet-outage allowances rather than hiding them,
  cook **events** in the recorder (so an outage is visible in the record and in
  the estimate), a **light theme**, and a reproducible screenshot command.
  Verified by running it: `npm run screenshots` → four images from the real
  renderer, and four consecutive replay runs leave `settings.json` byte-identical.
  Two defects were found by looking at the result rather than the build output —
  a probe subline clipped to `43° to go · targ…`, and probe panels pinned into
  narrow tracks with a third of the window empty. Both fixed.
  The new contrast check also caught a **pre-existing** dark-theme failure
  (`--danger` 4.30:1 on `--bg-card2`).
- **Recovery after a disconnect is fixed on iOS (2026-09-19).** The retry ladder
  had never once recovered a dropped link: every recovery in the device log came
  from relaunching the app by hand, with gaps of 2, 12 and 40 minutes. Two
  reasons — the app wrapped `central.connect` in a timeout and *cancelled* it,
  throwing away the standing request the system would have completed on its own;
  and the ladder is `Task.sleep`, which iOS freezes the moment the phone is
  pocketed, so recovery only ever worked while someone was watching the screen.
  Now the system holds the reconnect and the ladder is only the backstop for a
  connect that never established. Measured on hardware at -95 dBm: **8–17s,
  automatic**. Three further defects fell out of testing it — a zombie poll loop
  logging a failure every 5s forever (a cancelled task does not interrupt an
  await already in flight), a fast path that skipped discovery and turned a 15s
  first connect into silence, and three reconnect guards that returned without
  logging, which is why "never reconnected" had looked like "reconnected slowly".
- **Next:** notifications for method stages on the desktop (iOS schedules them;
  the desktop does not yet) · interruption markers drawn on the cook chart ·
  the two remaining DoD boxes (Bluetooth permission UX, auto-reconnect proven
  across real drops).
- **Now:** A **native iOS app** landed (`ios/`, ADR 0006). The BLE protocol is
  ported to Swift as `PitBossKit`; the per-model command/parse routines still run
  as JavaScript (on JavaScriptCore) out of the same `grills.json` pytboss uses, so
  all **128 grill models** are supported rather than just the dev's. Correctness is
  pinned to pytboss by generated golden vectors — `npm run ios:verify` → **582
  checks, all 128 models**. Builds warning-free; security pass clean (SECURITY.md,
  2026-09-18).
  The app **builds clean and runs** (Xcode 26.6 / iOS 26.5 simulator, `npm run
  ios:app`): 128 models load, both themes verified on screen, unified log writing.
  Two bugs were caught by actually running it — the UI ignored the OS appearance
  (`@Environment(\.colorScheme)` read on an `App` silently returns a default), and
  the nav title rendered white-on-light. Both fixed.
  - **Not yet on hardware, and has never talked to a grill.** The simulator has no
    Bluetooth radio (`CBCentralManager` → `.unsupported`), so the entire BLE path
    is unexercised outside the conformance vectors.
- **iOS is on the phone and talking to the grill.** Installed to the iPhone
  (team `24PG2KGN86`), and a real cook read decoded end-to-end:
  `[state] status+temps — grill 211° set 250° p1 187° on=true`. Setup is one tap:
  the control board is detected from the BLE advertisement and fully determines
  decoding, so **there is no model picker** — the firmware reports no chassis
  model anyway (ADR 0003). Auto-reconnect ported from the sidecar (3s→30s
  backoff, `ReconnectPolicy`, checked).
- **Graceful shutdown is ported** (`ios/PitBossKit/Sources/PitBossKit/Shutdown.swift`),
  same thresholds as the desktop, with `scripts/test-shutdown.mjs` ported case for
  case into `pitboss-verify`. Cook charts + the latched component-activity
  timeline are in too. `UIBackgroundModes: bluetooth-central` keeps a cool-down
  running when the phone is pocketed.
- **Cook history persists** (`CookStore.swift`) in the **desktop's own JSONL
  format** — a phone cook opens in the desktop app, checked by parsing a
  Swift-written file with the desktop's `readCook` (`npm run ios:interop`).
  Past cooks replay their curve + activity timeline and can be named/deleted.
- **Probe targets + naming** (`ProbeTargets.swift`): app-side targets for every
  probe with edge-triggered alerting (hysteresis + over-target escalation, ported
  from the recorder), pushed to the board only where it has a command — PBL has
  probe 1 only. Tap a probe tile to set it.
- **Setpoint ladder learned from the grill** (`LadderInference.swift`): the ladder
  is per-model and the firmware reports no model, so rather than asking, the app
  eliminates candidate models from what the grill accepts or refuses. **Rests on
  one unverified behaviour** — whether `grillSetTemp` reports the accepted value
  or echoes the request. Every `requested → reported` pair is logged; one cook
  with a 190° pick settles it.
- **Pellet hopper estimate** (`PelletEstimate.swift`): auger run-time integrated
  to a level bar with hours-left from the recent duty cycle, refill/empty
  recalibration, and a 10s clamp so a dropped link can't empty the hopper on
  paper. Prime is now a **momentary 5s burst** matching the desktop, not a
  toggle — a toggle could leave the auger feeding. Prime and power-off confirm.
- **Maintenance tracking + pre-cook checklist**: `Maintenance.swift` ports the
  desktop's cleaning cadence (5 cooks / 30h / 3 flare-ups) with its unit tests;
  a launch-time checklist offers "clean the firepot" and "fill the hopper", each
  skippable, each wired to the counter it resets.
- **Setpoint ladder + grate calibration** (on-grill feedback, 2026-09-18): the
  preset list defaults to the **firmware-verified 10-step PBL ladder** rather
  than a union or intersection of the catalogue (both of which were wrong in
  opposite directions), with a one-tap chooser showing candidate ladders as
  values. Grate calibration records the controller-vs-grate offset as a
  **display-only** second reading — the RTD sits on the barrel wall, so a 25–50°
  gap is expected, not a failed sensor.
- **Meat & cut catalogue** (`MeatCatalog.swift`): ~40 cuts with target
  temperatures that keep **USDA safe minimums**, **doneness preferences** and
  **barbecue texture temps** as distinct kinds rather than one flat list.
  Picking a cut sets the target and names the probe. Brisket is split by
  portion (packer / flat / point / burnt ends), with a check enforcing that the
  lean flat is pulled before the fatty point. Safety invariants are
  checked (every poultry cut offers 165°; nothing marked a safe minimum sits
  below its own floor, which is per-cut where the product differs).
- **Cook presets** (`startCook`/`planCook`): pick a cut and the grill setpoint,
  probe target and probe name are set together, snapped onto the grill's own
  ladder with the substitution shown rather than made silently. Cuts split by
  portion (brisket packer/flat/point/burnt ends, pork butt/picnic, three rib
  cuts) with checks enforcing the orderings that matter.
- **Cook continuity** (from real use, 2026-09-18): a cook is the *food*, not the
  fire — pellet outages, relights, dropped links and app restarts no longer
  split the record. One file spans them with each interruption written in as an
  event and drawn on the chart; relaunching mid-cook resumes rather than
  starting over. Closed only after 2h off. Event lines use `at` not `t` so the
  desktop reader still parses the file (checked).
- **Cook methods** (`CookMethod.swift`): 3-2-1 / 2-2-1 ribs, 0-400 wings, Texas
  crutch, reverse sear, spatchcock, hot-and-fast — staged instructions attached
  to the cuts they apply to. Chicken guidance raised throughout (dark meat
  175–185°, wings 185°, "165° is a floor not a target").
- **Landscape layout**: two columns past 640pt wide.
- **Connect reliability** (from on-grill use): the connect timeout was 30s but a
  weak link genuinely took **84s** to establish — the app reported failure over a
  connection that was succeeding, and left CoreBluetooth connecting underneath.
  Now 90s with proper cleanup, an elapsed counter so a long connect doesn't read
  as a hang, and a `link established in Ns` log line that tells a slow connect
  apart from a dropping link.
- **Methods are followable, and cooks are estimated** — starting a method makes
  it the current cook type and **schedules** a notification per stage (so 3-2-1's
  "time to wrap" fires with the app killed); per-probe ETAs are stall-aware
  (+90m before the stall, refuse during it) and add ~1h per recent pellet outage,
  with every allowance declared rather than folded in.
- **Shared cooking data extracted** to `data/cooking.json` (ADR 0007): iOS now
  loads the catalogue from it rather than Swift literals, with all checks still
  passing and a drift guard against the vendored copy. This is the foundation
  for the desktop port.
- **Desktop screen-space pass started**: the dashboard was one 1120px column at
  any window size. It now splits — readouts left, curve right — with the probe
  panels flowing beneath, and charts sized from available height.
- **`npm run stop` / `npm run restart` added** — closing a long-standing gap.
  The script matches only this project's processes and stops the main one first,
  because a naive pattern matches the helpers and leaves the main process
  holding the Bluetooth connection.
- **Next (iOS):** prove auto-reconnect and the shutdown chain on a real cook
  (signal at the grill is ~-95 dBm, which is its own problem), then pellet
  estimation, anomaly detection, background notifications.
- **Next (desktop):** calibrate the pellet feed-rate, and close the remaining DoD
  gaps (packaged-app verify, Bluetooth permission UX, auto-reconnect proof, README).
- **Anomaly detection + notifications ported** (`Thermal.swift`,
  `Notifications.swift`): lid-open vs. starving-fire discrimination with the
  desktop's thresholds and unit tests, and lock-screen alerts (time-sensitive
  only for the fire-safety ones). **iOS now has feature parity with the desktop
  app** — bar a real cook to prove it.
- **Also on the production-readiness radar** (standing-expectation gaps): the
  desktop UI is **dark-only** (the iOS app ships both themes, verified against WCAG
  AA by `npm run ios:contrast`); **iOS now has a canonical screenshot harness**
  (`npm run ios:screens`, replay-driven — the desktop still has only the ad-hoc
  `PITBOSS_SHOT`); and the desktop's own screenshot path is still the ad-hoc `PITBOSS_SHOT`. Pre-existing dependency
  bumps outstanding: `aiohttp`, `idna` in `requirements.txt`.
- **Later:** Cross-platform packaging (Windows/Linux), cook-history viewer polish,
  signed/notarized macOS build, and an App Store or TestFlight decision for iOS.

## Links
Decisions: `docs/adr/` · Security: `SECURITY.md` · Usage: `README.md` · iOS: `ios/README.md`
Test plans: `docs/test-plan.md` (comprehensive on-grill) · `docs/detection-test-plan.md` (alerts)
Presentation: `docs/session-review.html` (build review + human-AI case study)
