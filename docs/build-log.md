# Build log

The narrative record of how this project was built — extracted from the
`PROJECT.md` charter on 2026-09-20, where it had accreted into a 158-line
"Now / Next" section that was no longer either. The charter holds the *current*
state; this holds the story.

**Newest first. Every entry is true as of its own date and may be superseded by
a later one** — that is what a log is for, and it is why entries are not edited
after the fact to match what came later.

A theme runs through all of it, and it is the most transferable thing here:
**almost every defect below was found by running the app and looking at it, not
by the build.** A clean compile said nothing about a clipped label, a panel that
never populated, a reconnect that never fired, or a log line that was silently
skipped.

---

## 2026-09-19 — Recovery after a disconnect (iOS)

The retry ladder had **never once** recovered a dropped link. Every recovery in
the device log came from relaunching the app by hand, with gaps of 2, 12 and 40
minutes. Two independent causes:

- The app wrapped `central.connect` in a timeout and then *cancelled* it,
  throwing away the standing request the system would have completed on its own.
- The ladder is `Task.sleep`, which iOS freezes the moment the phone goes in a
  pocket — exactly when a six-hour cook needs it. Recovery only ever worked while
  someone was watching the screen.

Now the system holds the reconnect and the ladder is only the backstop for a
connect that never established. Measured on hardware at -95 dBm: **8–17s,
automatic**.

Three further defects fell out of testing it:

- A zombie poll loop logging a failure every 5s forever — cancelling a task does
  not interrupt an `await` already in flight.
- A fast path that skipped discovery, turning a 15s first connect into silence.
- Three reconnect guards that returned **without logging**, which is why "never
  reconnected" had looked like "reconnected slowly".

## 2026-09-19 — Shared cooking knowledge, and the desktop catches up

`data/cooking.json` became the one source of truth for 45 cuts, 7 methods and the
USDA floors (ADR 0007, 0009); `data/estimate-vectors.json` the one definition of
what the cook-time estimator does. Both apps read both, and `npm test` fails if a
vendored copy drifts or if the two estimators disagree. **The guard was itself
verified by poisoning a vector and confirming *both* harnesses failed on the same
assertion** — an unverified guard is a guess.

The desktop gained the cut picker (two screens — choosing a cut shows that cut and
nothing else), named methods with stage tracking, per-probe ETAs that declare
their stall and pellet-outage allowances rather than hiding them, cook **events**
in the recorder, a **light theme**, and a reproducible screenshot command.

Verified by running it: `npm run screenshots` → four images from the real
renderer, and four consecutive replay runs leave `settings.json` byte-identical.

Two defects found by looking at the result rather than the build output: a probe
subline clipped to `43° to go · targ…`, and probe panels pinned into narrow tracks
with a third of the window empty. Both fixed. The new contrast check also caught a
**pre-existing** dark-theme failure — `--danger` at 4.30:1 on `--bg-card2`.

Also landed: the desktop screen-space pass (the dashboard had been one 1120px
column at any window size; it now splits readouts left / curve right, with probe
panels flowing beneath and charts sized from available height), and
`npm run stop` / `npm run restart`, closing a long-standing gap. The stop script
matches only this project's processes and stops the main one first, because a
naive pattern matches the Electron helpers and leaves the main process alive,
still holding the Bluetooth connection.

## 2026-09-18 — What the grill taught us

Feedback that could only come from a real cook on real hardware.

**Connect reliability.** The connect timeout was 30s, but a weak link genuinely
took **84s** to establish. The app was reporting failure over a connection that
was succeeding, and leaving CoreBluetooth connecting underneath. Now 90s with
proper cleanup, an elapsed counter so a long connect doesn't read as a hang, and a
`link established in Ns` log line that tells a slow connect apart from a dropping
link.

**Setpoint ladder + grate calibration.** The preset list defaults to the
firmware-verified 10-step PBL ladder rather than a union or intersection of the
catalogue — both of which were wrong, in opposite directions — with a one-tap
chooser showing candidate ladders as values. Grate calibration records the
controller-vs-grate offset as a **display-only** second reading: the RTD sits on
the barrel wall, so a 25–50° gap is expected, not a failed sensor.

**Cook continuity** (ADR 0008). A cook is the *food*, not the fire. Pellet
outages, relights, dropped links and app restarts no longer split the record; one
file spans them with each interruption written in as an event and drawn on the
chart, and relaunching mid-cook resumes rather than starting over. Closed only
after 2h off. Event lines use `at`, not `t`, so the desktop reader still parses
the file (checked).

## 2026-09-18 — iOS reaches feature parity

Ported from the desktop, each with its tests carried across:

- **Graceful shutdown** (`Shutdown.swift`) — same thresholds, with
  `scripts/test-shutdown.mjs` ported case for case into `pitboss-verify`.
  `UIBackgroundModes: bluetooth-central` keeps a cool-down running when the phone
  is pocketed.
- **Cook history** (`CookStore.swift`) in the **desktop's own JSONL format** — a
  phone cook opens in the desktop app, checked by parsing a Swift-written file
  with the desktop's `readCook` (`npm run ios:interop`).
- **Probe targets + naming** (`ProbeTargets.swift`) — app-side targets for every
  probe with edge-triggered alerting (hysteresis + over-target escalation), pushed
  to the board only where it has a command; PBL has probe 1 only.
- **Setpoint ladder inference** (`LadderInference.swift`) — the ladder is
  per-model and the firmware reports no model, so rather than asking, the app
  eliminates candidates from what the grill accepts or refuses (ADR 0010). **Rests
  on one unverified behaviour**: whether `grillSetTemp` reports the accepted value
  or echoes the request. Every `requested → reported` pair is logged; one cook with
  a 190° pick settles it.
- **Pellet hopper estimate** (`PelletEstimate.swift`) — auger run-time integrated
  to a level bar, hours-left from recent duty cycle, refill/empty recalibration,
  and a 10s clamp so a dropped link can't empty the hopper on paper. Prime became a
  **momentary 5s burst** matching the desktop rather than a toggle, because a
  toggle could leave the auger feeding. Prime and power-off confirm.
- **Maintenance + pre-cook checklist** (`Maintenance.swift`) — the desktop's
  cadence (5 cooks / 30h / 3 flare-ups) with its unit tests; a launch-time
  checklist offers "clean the firepot" and "fill the hopper", each skippable, each
  wired to the counter it resets.
- **Meat & cut catalogue** (`MeatCatalog.swift`) — ~40 cuts keeping **USDA safe
  minimums**, **doneness preferences** and **barbecue texture temps** as distinct
  kinds rather than one flat list. Brisket split by portion, with a check enforcing
  that the lean flat is pulled before the fatty point. Safety invariants checked:
  every poultry cut offers 165°, and nothing marked a safe minimum sits below its
  own floor.
- **Cook presets** (`startCook` / `planCook`) — pick a cut and the setpoint, probe
  target and probe name are set together, snapped onto the grill's own ladder with
  the substitution **shown rather than made silently**.
- **Cook methods** (`CookMethod.swift`) — 3-2-1 / 2-2-1 ribs, 0-400 wings, Texas
  crutch, reverse sear, spatchcock, hot-and-fast. Chicken guidance raised
  throughout: dark meat 175–185°, wings 185°, "165° is a floor, not a target."
  Starting a method makes it the current cook type and **schedules** a notification
  per stage, so 3-2-1's "time to wrap" fires with the app killed.
- **Anomaly detection + notifications** (`Thermal.swift`, `Notifications.swift`) —
  lid-open vs. starving-fire discrimination with the desktop's thresholds and unit
  tests, and lock-screen alerts, time-sensitive only for the fire-safety ones.
- **Landscape layout** — two columns past 640pt wide.

## 2026-09-18 — iOS on the phone, talking to the grill

Installed to the iPhone (team `24PG2KGN86`), and a real cook read decoded
end-to-end:

```
[state] status+temps — grill 211° set 250° p1 187° on=true
```

Setup is one tap. The control board is detected from the BLE advertisement and
fully determines decoding, so **there is no model picker** — the firmware reports
no chassis model anyway (ADR 0003).

## 2026-09-18 — The native iOS app lands (ADR 0006)

The BLE protocol ported to Swift as `PitBossKit`. The per-model command and parse
routines still run as JavaScript on JavaScriptCore, out of the same `grills.json`
pytboss uses, so **all 128 grill models** are supported rather than just the
dev's. Correctness pinned to pytboss by generated golden vectors.

Builds warning-free on Xcode 26.6 / iOS 26.5 simulator; 128 models load, both
themes verified on screen, unified log writing.

Two bugs caught by actually running it: the UI ignored the OS appearance
(`@Environment(\.colorScheme)` read on an `App` silently returns a default), and
the nav title rendered white-on-light. Both fixed.

> **As of this entry, the app had never talked to a grill.** The simulator has no
> Bluetooth radio (`CBCentralManager` → `.unsupported`), so the entire BLE path was
> unexercised outside the conformance vectors. Superseded later the same day — see
> *iOS on the phone, talking to the grill* above.
