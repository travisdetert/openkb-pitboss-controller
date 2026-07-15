<!--
  PROJECT.md — the project charter. One scannable file that answers
  "what is this, and how do we know when it's done?"
  Keep it short. Update Status / Now / Next as work lands.
  Status values: Idea · Building · Usable · Done · Parked
-->
# openkb-pitboss-controller — Charter

**Status:** Building
**Updated:** 2026-06-26

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
- [ ] Notable decisions recorded (docs/adr/)

## Now / Next
- **Now:** Pre-first-commit. Working tree has the full Electron+sidecar stack
  (controls, recorder, store, logging) but nothing is committed or pushed yet.
- **Next:** First commit + initial security pass before push; verify the packaged
  `.app` runs with the bundled `.venv`/sidecar on a clean profile; confirm the
  macOS Bluetooth permission prompt + denied-state handling.
- **Later:** Cross-platform packaging (Windows/Linux), cook-history viewer UI,
  multi-grill support, signed/notarized macOS build.

## Links
Decisions: `docs/adr/` · Security: `SECURITY.md` · Usage: `README.md`
