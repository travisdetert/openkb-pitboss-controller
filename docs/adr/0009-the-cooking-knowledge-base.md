# 9. The cooking knowledge base

Date: 2026-09-18

## Status

Accepted

## Context

Neither app originally knew anything about food. You set a grill temperature and
a probe target as bare numbers, and whether 165° or 203° was right was your
problem. Two things pushed against that:

- **Chicken is commonly undercooked.** 165° is a floor, and dark meat is far
  better at 175–185°, but an app that shows a bare number teaches nobody that.
- **The technique is the part people look up.** "3-2-1" and "0 to 400" are not
  temperatures, they are procedures. A target of 203° tells you nothing about
  when to wrap.

The hazard in encoding this is that food-safety figures and cooking preferences
look identical once they are both "a temperature in a list". Flattening them is
how someone reasons their way from "chicken 165°" to "well, brisket goes to 203
and steak to 135, so 150 is probably fine for chicken".

## Decision

Build a catalogue, and make the *kind* of each number explicit.

### Three kinds of number, never flattened

| Kind | Meaning | Example |
| --- | --- | --- |
| `safeMinimum` | USDA FSIS floor. Not a preference. | Poultry 165°, ground 160° |
| `doneness` | A preference for whole muscle. | Steak rare 125° … well 160° |
| `texture` | Where collagen renders, far past any safety line. | Brisket 203° |

Each is rendered differently and labelled with what it is. A target **below** a
floor — rare steak, medium-rare duck — is offered but flagged, because those are
legitimate choices people make; hiding them would be paternalistic and hiding
that they are under the floor would be worse.

### The floor is a property of the product

Per-category floors were not enough: a fully cooked ham being *reheated* is safe
at 140° while raw pork is 145°. `MeatCut.safeFloorOverride` carries the
difference. This was found by a check, not by review.

### Safety invariants are checked, not reviewed

The class of bug here has physical consequences, so it is asserted:

- every poultry cut offers the 165° floor
- nothing marked a `safeMinimum` sits below its own floor
- barbecue cuts suggest their *texture* temperature (a brisket pulled at 145° is
  safe and inedible)
- the lean brisket flat is pulled **before** the fatty point; leaner baby backs
  finish at or before spares

### Cuts split where the portions genuinely differ

Brisket packer / flat / point / burnt ends; pork butt / picnic; spare /
St. Louis / baby back. One averaged entry is how a lean flat ends up dry.

### Methods are procedures, and can be *followed*

3-2-1, 2-2-1, 0-400, Texas crutch, reverse sear, spatchcock, hot-and-fast.
Starting one makes it the current cook type and **schedules** a local
notification for each stage — scheduled, not posted, because the stages are
hours apart and must fire with the app killed. Methods whose stages are
temperature-driven rather than timed say so and promise no reminders.

### Estimates refuse rather than guess

`CookEstimate` is stall-aware, because a naive extrapolation is wrong in both
directions:

| Phase | Behaviour |
| --- | --- |
| Before the stall | naive **+ 90 min** — otherwise badly optimistic |
| Flat in the band | *"stalled 40m — normal, it can last hours"*, no number |
| Climbing in the band | half allowance |
| Past the band | plain extrapolation — the reliable phase |
| Non-stalling target | no allowance |

A recent **pellet outage adds ~1 hour**, drawn from the cook's own event record
(ADR 0008). Every allowance is declared — *"includes ~1½h for the stall and ~1h
for the pellet outage"* — never folded in silently. Flat, falling, or under
1.5°/hr yields a reason, not "41 hours".

## Consequences

- The app now teaches rather than just reports, which is the difference between
  a remote control and something worth cooking with.
- It carries food-safety claims. They are sourced to USDA FSIS, kind-tagged, and
  covered by checks — but they are still claims, and correcting one has to be
  easy. That is the motivation for ADR 0007.
- Estimates will be wrong sometimes; the mitigation is that they are hedged
  (`~`), declare their padding, and decline when the data can't support them.
- The catalogue is iOS-only today. ADR 0007 covers bringing it to the desktop
  without ending up with two divergent copies of the safety data.
