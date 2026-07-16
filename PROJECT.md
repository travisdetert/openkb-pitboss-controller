<!--
  PROJECT.md — the project charter. One scannable file that answers
  "what is this, and how do we know when it's done?"
  Keep it short. Update Status / Now / Next as work lands.
  Status values: Idea · Building · Usable · Done · Parked
-->
# openkb-pitboss-controller — Charter

**Status:** Usable
**Updated:** 2026-07-16

## Goal
A local, account-free desktop app to control a Pit Boss pellet grill over
Bluetooth. It talks directly to the grill's Mongoose-OS / PBL control board via
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
- [x] Unified, tailable main+renderer log (`/tmp/openkb-pitboss.log`)
- [ ] Packaged macOS app runs from a clean machine (bundled venv/sidecar verified)
- [ ] Bluetooth permission UX is graceful: clear prompt + guidance when denied
- [ ] Auto-reconnect proven across real BLE drops (short antenna range)
- [ ] Runs/builds from a fresh checkout (README documents how) — incl. icon build
- [ ] Security pass run; findings fixed or accepted (SECURITY.md)
- [x] Notable decisions recorded (docs/adr/ — 0001 process, 0002 graceful shutdown)

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

## Now / Next
- **Now:** The monitoring + safety build is committed (9 commits) and passed its
  first on-grill validation pass (2026-07-16): warm-up clean, lid-open caught at
  −27°/min, and the graceful shutdown ran the full cool-to-200 → off → cool-down
  chain on real fire.
- **Next:** Land the three fixes the on-grill test surfaced — suppress the flare-up
  detector during a commanded cool-down, make a cleared probe target clear its
  warning, and add a dismissible in-app alert banner. Then calibrate the pellet
  feed-rate, and close the remaining DoD gaps (packaged-app verify, Bluetooth
  permission UX, auto-reconnect proof, README, security pass).
- **Later:** Cross-platform packaging (Windows/Linux), cook-history viewer polish,
  signed/notarized macOS build.

## Links
Decisions: `docs/adr/` · Security: `SECURITY.md` · Usage: `README.md`
