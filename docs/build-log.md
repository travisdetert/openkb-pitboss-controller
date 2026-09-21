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

## 2026-09-20 — Pre-push cleanup, and the permission screen that was never written

Two months of work had been sitting uncommitted since July — the entire iOS
app, the shared cooking knowledge base, the desktop cooking UI. It went in as
eight commits, then the branch was taken through the gate it had never passed.

**Every known dependency CVE closed.** osv-scanner went from 45 findings across
11 packages to zero. `aiohttp` 3.14.1 → 3.14.3. `idna` was the interesting one:
never pinned at all, so the scanner resolved it transitively to a vulnerable
3.9.0 while the working `.venv` had long since floated to 3.18 — the risk was
never on this machine, it was on a fresh checkout. It carries a `>=3.15` floor
now. The 41 npm findings were all dev-only toolchain and cleared without
touching a runtime dependency.

Then the same mistake, committed by the fix: a new `requirements-dev.txt`
declared `Pillow>=11.0`, and a floor is exactly what a scanner resolves, so that
reintroduced seven findings up to 8.7. Caught only by **rescanning after the
change instead of trusting the earlier clean result**.

**A security pass over the whole branch.** Clean. semgrep's six path-traversal
hits are written up in `SECURITY.md` rather than suppressed — all six are
`path.join` in the recorder, four guarded on the immediately preceding line by
`isValidCookId`, whose regex is anchored to digits and dashes so no `.` or `/`
survives it. A suppression comment records a conclusion; the write-up records
the reasoning, so the next pass doesn't re-derive it.

**The fresh-checkout claim, tested by actually doing it.** Cloning clean and
following the README failed twice: `npm run icon` called a bare `python` that
modern macOS does not provide — `scripts/setup.mjs` already knew this and probes
for `python3`, so the inconsistency was in `package.json` alone — and nothing
installed the Pillow that `make_icon.py` imports.

**The Bluetooth permission screen** (ADR 0011), and a chain of four defects that
only running the app could have surfaced:

1. **No banner at all.** The one-shot event was being wiped seconds later by the
   real sidecar's next `not_found`. Pushing one message is not simulating a
   blocked radio; a blocked radio cannot report `not_found` *at all*.
2. **The button stretched across the entire window** — `.btn` is `flex: 1`, for
   the toolbar row where buttons share width evenly.
3. Fixing that exposed something much older: **`.btn-save` sat ~100 lines above
   `.btn`** in the stylesheet, and both are one class deep, so `.btn`'s own
   background won on source order. Every primary button in the app — the
   wizard's "Scan for grills" included — had been quietly rendering grey.
4. Which exposed the bug that grey had been **masking**: with primary buttons
   finally filled, their hardcoded `#1a1208` label sat on the light theme's much
   darker `--flame` at **3.45:1**, under the 4.5:1 AA floor. Now an `--on-flame`
   token, and `check-contrast` grew a category for labels on accent fills —
   pairs the surface checks structurally could not see.

Each of those was found by the fix before it. None was visible in a clean build,
and the app compiled perfectly at every step.

### Later that day — what "build" actually meant

"Does it build?" had meant `tsc` for this project, and the packaged app had not
been produced since July while two months of code landed on top of it. Building
both for real: the Electron bundle packages (288M, sidecar frozen inside with no
external Python references, runs from the bundle) and `xcodebuild` reports BUILD
SUCCEEDED with no code warnings. Both were fine — but nothing in the tooling
could have said so, which was the actual problem.

The check that mattered was not the exit code: it was confirming that
`PBProtocol.js` — the Bluetooth guidance written hours earlier — was genuinely
*inside* the asar rather than merely on disk. That is the difference between a
feature existing and a feature shipping.

So packaging became a gate rather than an assumption: `/ship-check` now runs the
real packaging command per claimed platform and inspects the artifact, and the
harness `doctor` gained a fast staleness check for declared distributables.

### And a doctor, so a broken thing says why

`npm run doctor` — ~3s, ten checks, `.health.json`. Four are specific to this
project and each one is a question that has bitten it: the frozen sidecar has no
load path escaping the bundle (ADR-0005's first attempt shipped a venv that
worked only on the dev machine); the iOS conformance vectors have been run since
the Swift last changed; the screenshots still match the UI; a clean stop path
exists.

It proved its own point immediately. The first run reported "Screenshots: none
captured" and skipped the iOS check — both false, six PNGs and the whole Swift
package sitting right there. The helper used `require()` inside an ESM module,
which threw, was swallowed by a `catch`, and returned 0; the checks faithfully
reported the lie. **A check that lies is worse than no check**, so the comment
explaining it stays in the file.

It also surfaced a gap it cannot fix: this project has no linter. That is
recorded as SKIPPED rather than quietly passed.

The runner was initially vendored here — 377 lines of a harness capability
copied into a project that should only own `health.config.mjs`. The obstacle to
sharing it was small and specific: the runner resolved its root from its own
file location, so one shared copy would examine the harness directory instead of
the caller's.

That got fixed rather than accepted. `ROOT` is now the caller's working
directory, the runner lives once in the harness and is linked to
`~/.claude/doctor.mjs`, and this project's `package.json` points at it. The
duplicate is deleted. What stays here is `health.config.mjs`, which is the part
that was ever project-specific.

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
