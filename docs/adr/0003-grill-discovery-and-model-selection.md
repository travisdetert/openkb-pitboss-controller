# 3. Grill discovery and model selection

Date: 2026-07-22

## Status

Accepted

## Context

The app was built and hardcoded to the developer's grill: `store.ts` defaults to
`grillName: 'PBL-'` and `grillModel: 'PB1100PSC3'`, and the renderer auto-connects
to those on boot. For anyone else to use it, the app must discover their grill and
learn its model — the model drives capabilities (`pytboss.get_grill(model)`: temp
range, preset ladder, probe count, lights).

### What the board actually self-reports (probed on a live PB1100PSC3)

`Sys.GetInfo` → `{ id: "PBL-<MAC>", app: "Lowes", fw_version, mac, arch: esp32 }`;
`PB.GetFirmwareVersion` → `{ firmwareVersion: "0.5.7" }`. **There is no grill-model
field anywhere** — not in `Sys.GetInfo`, not in `Config.Get`.

So the exact chassis model (`PB1100PSC3`) is **not auto-detectable**. What *is*
knowable:

- The **control board** is identifiable from the BLE name prefix (`PBL-…` → `PBL`).
- In `pytboss`, the **command protocol is defined at the control-board level**, not
  the model — all grills on the `PBL` board share identical get-status /
  set-temperature / probe / light commands. **Control therefore works for any PBL
  grill regardless of the exact model picked.**
- Only **6 of 128** supported models are on the `PBL` board. The model selection is
  a short, pre-filtered list, and the only thing it changes is UI **capabilities**
  (temp range, increments, probe count, lights) — a wrong pick is non-fatal.

## Decision

Add a **first-run discovery wizard**, gated on a persisted "configured" flag; the
existing `SettingsStore` (`userData/settings.json`) is the store — no new storage.

1. On launch, if the grill has **not** been configured, show the wizard instead of
   auto-connecting to a hardcoded default.
2. **Scan** (the sidecar already supports `BleakScanner`) and list nearby grills by
   stable BLE name.
3. From the selected grill's **name prefix, derive the control board** and
   **pre-filter the model list** to that board's grills (via `get_grills(control_board)`),
   falling back to the full list if the prefix is unknown.
4. The user **picks their model once**; save `grillName` + `grillModel` +
   `grillConfigured: true` to the store, then connect.
5. Subsequent launches auto-connect to the saved grill. A **"Change grill"** action
   in Settings re-runs the wizard.

New sidecar command `list_models` (optionally filtered by control board) returns
`{ name, control_board, min_temp, max_temp, meat_probes, has_lights }` per model,
so the renderer can render an informative picker without duplicating the pytboss
registry.

## Consequences

- **Anyone with a Pit Boss grill can use the app** — scan, pick, done — with the
  data staying local (no cloud, consistent with the project's premise).
- Because control is control-board-level, the app is usable even before the model
  is perfectly matched; the model only refines the on-screen capabilities.
- Auto-detecting the *control board* (from the name) means the model picker is
  short and relevant, not a 128-item list.
- The developer's specific defaults (`PB1100PSC3`) stop being special — they become
  one option among the PBL models, chosen through the same wizard as everyone else.
