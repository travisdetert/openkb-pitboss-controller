# 11. Reporting a blocked radio, and simulating one

Date: 2026-09-20

## Status

Accepted

## Context

The desktop app had no Bluetooth permission handling. `_attempt_connect` caught
every scan exception, set the device to `None`, and emitted one status:

```python
except Exception as ex:          # any failure at all
    device = None
if device is None:
    emit({... "reason": "not_found"})
```

So four different situations produced one message:

| What actually happened | What the app said |
| --- | --- |
| The user denied the permission prompt | No grills found |
| A policy blocks Bluetooth | No grills found |
| The radio is switched off | No grills found |
| This Mac has no BLE radio | No grills found |
| No grill in range | No grills found |

The first-run wizard elaborated: *"Make sure it's powered on and in range, then
scan again."* For four of those five rows that is advice to go outside and debug
a grill that is working perfectly, while the actual fix is a toggle on the
machine in front of you. The iOS app had had this right since it was written
(`BLETransport.waitUntilReady` names the `.unauthorized` case and quotes the
Settings path); the desktop never did.

Two questions had to be answered: how to *know* the reason, and how to *verify*
the handling of it, given that macOS Bluetooth permission cannot be revoked by
any means the test suite could drive.

## Decision

**1. Read the reason from bleak's structured error, never from its message.**

bleak 3.0 raises `BleakBluetoothNotAvailableError` carrying a
`BleakBluetoothNotAvailableReason` enum. That enum is mapped to a stable wire
code (`denied`, `restricted`, `denied_unknown`, `powered_off`, `no_radio`,
`unknown`) which the app owns.

The alternative — matching `"not authorized"` or `"powered off"` against
`str(ex)` — would work today and break silently on any upgrade that rewords a
string, degrading straight back to "no grills found". A wire code we define
cannot be reworded by a dependency.

**2. Carry it on the existing `status` event, not a new one.**

A blocked radio *is* a connection state. Reusing `status` means the renderer's
existing re-render path handles it, and — the part that matters — **any later
status clears it**, so recovery needs no separate "unblocked" event. The sidecar
keeps retrying regardless, so granting permission reconnects with no rescan and
no relaunch.

**3. The banner is not dismissible.**

Without the radio the app cannot do its one job. A dismissible warning here
would leave a dashboard that simply never populates, which is the state we are
trying to eliminate.

**4. Simulate a blocked radio at the sidecar boundary, not by pushing a message.**

`PITBOSS_BT_BLOCKED=<reason>` rewrites *outgoing sidecar status events* rather
than injecting one into the renderer.

The first implementation did inject one, and it did not work: the real sidecar
kept scanning underneath and its next `not_found` wiped the banner seconds
later, well before the screenshot. That failure is the argument for this
decision. **When the radio is genuinely blocked the sidecar cannot report
`not_found` at all**, so suppressing those is not a convenience — it is the
difference between simulating the condition and merely displaying its message.

## Consequences

- The four cases are distinguishable, and the Settings button appears only where
  System Settings is actually the fix — offering it for "this Mac has no BLE
  radio" would be a false promise.
- The denial path is reproducible in CI and in `npm run screenshots`, so
  `docs/screenshots/bluetooth-denied*.png` regenerate with no hardware and no
  hand-staging, in both themes.
- **The detection branch itself remains unexercised by a real denial.** The
  simulation covers everything downstream of the `except` clause; only a real
  `tccutil reset Bluetooth` exercises the clause. This is tracked as its own
  open Definition-of-Done item rather than folded into the one it sits beside.
- Making primary buttons render filled for the first time (they had been losing
  to `.btn` on CSS source order) exposed a latent AA failure: the hardcoded
  label colour scored 3.45:1 on the light theme's darker `--flame`. It is now an
  `--on-flame` token, and `scripts/check-contrast.mjs` gained a category for
  labels on accent fills — pairs the surface checks structurally could not see.
