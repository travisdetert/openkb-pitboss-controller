# 10. Resolving grill capabilities without a model number

Date: 2026-09-18

## Status

Accepted

## Context

ADR 0003 established that the firmware reports **no chassis model** — only
`PBL-<MAC>`, naming the control board. The desktop solves this with a first-run
wizard that asks the user to pick their model once.

On iOS the ask was rejected outright: *"if you can detect it why should I have
to do so?"* That is a fair challenge, and answering it exposed three separate
capability questions that had been conflated:

1. **Decoding and commands** — which routines parse frames and build commands.
2. **The setpoint ladder** — which temperatures the controller will accept.
3. **The temperature itself** — the controller's sensor is not where the food is.

## Decision

### Decoding: the board is sufficient, so never ask

Every one of the 19 control boards in `grills.json` has **exactly one** decoding
behaviour — verified, not assumed. The board is readable from the BLE name, so
it fully determines correct decoding and commands. There is no model picker.

### The ladder: default to the shortest, offer a correction

The ladder *does* vary within a board — PBL spans a 10-step and a 19-step
ladder. Both a union and an intersection were tried and both were wrong:

- **intersection** dropped 225°, 450°, 475° and 500° — real setpoints on the
  user's grill
- **union** offered 190° and 210°, which that grill does not have

The default is now the **shortest** ladder, on an asymmetry: a setpoint the
controller lacks fails *silently* — you tap it, nothing happens, with no way to
tell why — whereas a missing one is visible and one tap away. It also matches
the evidence in this repo: `docs/test-plan.md` E1 records the PBL firmware's
ladder skipping 250→300, which is the 10-step ladder.

Correction is **"My grill has different steps"**, which shows the candidate
ladders *as their values* and asks which matches the grill's display. Nobody
should need a part number to fix a list of numbers.

`LadderInference` additionally narrows from behaviour: a setpoint the grill
demonstrably refused is dropped, one it accepted is added. This rests on an
unverified assumption — that `grillSetTemp` reports the *accepted* value rather
than echoing the request — so it is advisory, fails safe, and every
`requested → reported` pair is logged so one cook settles it.

### Temperature: calibrate the display, never the logic

The controller's RTD sits on the barrel wall, not at grate level, so a
grate thermometer reading 25–50° lower is **normal and not a failed sensor**.
Grate calibration records the offset and shows *both* readings.

It is **display-only, deliberately.** The setpoint sent, the cool-to-200
shutdown chain, lid-open and flare-up detection all keep using the controller's
raw value, because that is the number the controller itself acts on. An offset
that silently shifted the safety thresholds would be a dangerous setting. Cook
files store the raw value, so an old cook still means what it meant.

## Consequences

- Setup is one tap: scan, tap the grill, connected.
- A PBL owner gets their exact ladder by default, and anyone else is one tap
  from theirs.
- Nothing in the safety path is affected by a cosmetic calibration.
- The inference is inert until `grillSetTemp`'s behaviour is observed on real
  hardware. If it echoes requests, nothing is ever eliminated and the default
  stands — which is the current behaviour anyway, so the failure mode is "no
  worse".
