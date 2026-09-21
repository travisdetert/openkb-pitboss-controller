<!--
  PROJECT.md — the project charter. One scannable file that answers
  "what is this, and how do we know when it's done?"
  Keep it short. Update Status / Now / Next as work lands.
  Status values: Idea · Building · Usable · Done · Parked
-->
# openkb-pit-boss — Charter

**Status:** Usable
**Updated:** 2026-09-20

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
This project ships **two apps** against one grill — a macOS Electron app and a
native iOS app (ADR 0006) — so the bar is grouped by what each item applies to.
An item is ticked when it has been *observed working*, never when it merely
builds.

### Both apps
- [x] One source of truth for cooking knowledge (ADR 0007, 0009): 45 cuts, 7
  named methods and the USDA floors in `data/cooking.json`, read by both apps,
  with a drift guard that fails `npm test` if a vendored copy diverges
- [x] One definition of the cook-time estimator, two implementations held to the
  same golden vectors (`data/estimate-vectors.json`) — `npm test` fails if the
  two ever disagree
- [x] A cook is the food, not the fire (ADR 0008): outages, relights, dropped
  links and app restarts are written into one cook as events, not split into new
  ones
- [x] The two apps read each other's cook files — a phone cook opens on the
  desktop, checked by parsing a Swift-written file with the desktop's own reader
  (`npm run ios:interop`)
- [x] Dark **and** light themes on both, OS-following with an in-app override,
  every colour from the token layer — WCAG AA verified by `npm test` and
  `npm run ios:contrast`
- [x] Screenshots are reproducible with no grill attached (`npm run screenshots`,
  `npm run ios:screens`)
- [x] Notable decisions recorded — `docs/adr/` 0001 process, 0002 graceful
  shutdown, 0003 grill discovery & model selection, 0004 local-only storage,
  0005 frozen sidecar binary, 0006 native iOS app, 0007 sharing the cooking
  knowledge base, 0008 a cook is the food not the fire, 0009 the cooking
  knowledge base, 0010 resolving grill capabilities, 0011 reporting a blocked
  radio — all eleven Accepted, and the ten that describe something built now
  say so in their Status line, so the harness dashboard can tell a shipped
  decision from one nobody has started
- [x] Data storage & backup decided: data in `userData` (not the repo), app name
  pinned, local-only backup accepted for a grill controller (ADR 0004)
- [x] Security passes run; findings fixed or accepted (SECURITY.md — 2026-07-19
  first push, 2026-07-21 session manager, 2026-09-18 ×3 for the iOS app)
- [x] A security pass covers the BLE reconnect rework and the whole unpushed
  branch (SECURITY.md — 2026-09-20): gitleaks, osv-scanner, npm audit and
  semgrep all clean, and semgrep's 6 path-traversal hits analysed and recorded
  as false positives rather than suppressed
- [x] Known dependency CVEs cleared — osv-scanner went from 45 findings across
  11 packages to **0**, and npm audit from 6 to 0 (2026-09-20)

### Desktop (Electron)
- [x] Connects to the grill over BLE by stable advertised name and reads live state
- [x] Core controls work end-to-end: set temp, set probe target, lights, prime, off
- [x] Cook recorder + native notifications (probe target, pellets, errors)
- [x] Unified, tailable main+renderer log (`/tmp/openkb-pit-boss.log`)
- [x] Graceful shutdown (cool-to-200 → off → device cool-down) — prevents the
  hopper burnback that motivated this project; **validated on the grill 2026-07-16**
- [x] Monitoring + fire-safety suite: per-source panels and charts, component
  activity timeline, estimated pellet level, anomaly detection (lid-open vs.
  out-of-pellets, over-temp, grease-fire flare-up), maintenance cycles, in-app
  status bar, header session clock
- [x] Cooking UI: cut picker, named methods with stage tracking, and per-probe
  ETAs that declare their stall and pellet-outage allowances rather than hiding
  them
- [x] Packaged app is self-contained: sidecar frozen to a standalone binary (no
  system Python/venv) — verified no external refs + runs from the bundle
  (ADR 0005). Bundle 357M → 288M
- [x] Works for anyone: the first-run wizard scans, finds the grill and picks the
  model — any Bluetooth Pit Boss grill, not just the dev's PB1100PSC3
- [x] A clean stop path (`npm run stop`) that cannot orphan a process still
  holding the Bluetooth connection
- [x] `npm test` green — 8 suites: thermal, shutdown, maintenance, config,
  estimate, cooking, shared-data drift, contrast (2026-09-19)
- [x] Bluetooth permission UX is graceful: a denial, a restriction, a radio
  that is off and a Mac with no BLE each say so by name, with the Settings
  button offered only where Settings is the fix — instead of all four reading
  as "no grills found". Read from bleak's structured error enum, not a parsed
  message. Verified on screen in both themes (2026-09-20)
- [ ] That denial path is confirmed against a *real* macOS denial. The UI is
  verified, but the detection branch itself has only ever run under simulation
  (`PITBOSS_BT_BLOCKED`) — a one-time `tccutil reset Bluetooth` would exercise
  it for real
- [x] Runs/builds from a fresh checkout, README documents how — incl. the icon
  build, verified by cloning clean and running it (2026-09-20). This caught two
  real breakages: `npm run icon` called a bare `python` that modern macOS does
  not have, and nothing installed the Pillow it imports
- [ ] The packaged app is smoke-tested on a clean Mac against a real grill

### iOS (ADR 0006)
- [x] Protocol ported to Swift (`PitBossKit`); the per-model command and parse
  routines run on JavaScriptCore from the same `grills.json` pytboss uses, so
  **all 128 models** are supported rather than only the dev's
- [x] Correctness pinned to pytboss by generated golden vectors —
  `npm run ios:verify`, **1346 checks**, including protocol conformance across
  all 128 models (2026-09-19)
- [x] Builds warning-free and runs on the phone (team `24PG2KGN86`); a real cook
  decodes end-to-end
- [x] Bluetooth permission UX is graceful: the usage description is declared, and
  a denial surfaces the exact Settings path instead of a silent no-op
- [x] Auto-reconnect proven across real BLE drops — **8–17s with no user action**,
  verified on the grill at -95 dBm (2026-09-19). The system holds the reconnect,
  so it completes with the app suspended; see `ios/README.md` → Staying connected
- [x] Graceful shutdown ported with the desktop's thresholds and its test cases;
  `UIBackgroundModes: bluetooth-central` keeps a cool-down running when the phone
  is pocketed
- [x] Cook history persists in the desktop's own JSONL format, replays its curve
  and activity timeline, and cooks can be named and deleted
- [x] Probe targets and naming, pellet-hopper estimate, maintenance tracking with
  a pre-cook checklist, anomaly detection, and lock-screen notifications
- [x] The setpoint ladder is resolved without a model number (ADR 0010) —
  candidates eliminated from what the grill itself accepts or refuses
- [ ] The ladder inference's one unverified assumption is settled: whether
  `grillSetTemp` reports the accepted value or echoes the request. Every
  `requested → reported` pair is logged; one cook with a 190° pick decides it

## Now / Next

**Now — both apps are verified, the branch is clean, and it is ready to push.**
The desktop's Bluetooth permission UX landed on 2026-09-20, closing the last
capability gap between the two apps.
Two months of work that had sat uncommitted since July landed in eight commits
on 2026-09-19/20. As of 2026-09-20: `npm test` green (8 suites),
`npm run ios:verify` 1346 checks across 128 models, `npm run ios:interop`
green, a full security pass clean (SECURITY.md), every known dependency CVE
closed (osv-scanner 45 → 0, npm audit 6 → 0), and a fresh clone verified to
set up, build, test and render its icons. **Nothing is pushed** — the branch is
8 ahead of `origin/main`, waiting on an explicit go.

**Next, in order:**
1. **Push.** The gate that was holding it — a security pass over the reconnect
   rework — is done and recorded.
2. **One cook with a 190° setpoint pick**, to settle whether `grillSetTemp`
   reports the accepted value or echoes the request — the single unverified
   assumption under the iOS ladder inference (ADR 0010). Every
   `requested → reported` pair is already logged, so the cook just has to
   happen. *One DoD box.*

**Then:** a real `tccutil reset Bluetooth` to exercise the denial branch rather
than its simulation · the clean-Mac packaged smoke test against a real grill · method-stage notifications on the desktop, which iOS already schedules ·
interruption markers drawn on the desktop cook chart · calibrating the pellet
feed-rate against a weighed hopper.

**Later:** cross-platform packaging (Windows/Linux), a signed and notarized macOS
build, cook-history viewer polish, and a TestFlight or App Store decision for iOS.

How all of this was built — including the defects that were only ever found by
running the app and looking at it — is in `docs/build-log.md`.

## Links
Decisions: `docs/adr/` · Security: `SECURITY.md` · Usage: `README.md` · iOS: `ios/README.md`
Build log: `docs/build-log.md` · Test plans: `docs/test-plan.md` (comprehensive on-grill) · `docs/detection-test-plan.md` (alerts)
Presentation: `docs/session-review.html` (build review + human-AI case study)
