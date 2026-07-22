# 4. Local-only data storage (no cloud backup in v1)

Date: 2026-07-22

## Status

Accepted

## Context

The "data storage & backup" standing expectation requires every data-persisting
app to decide, up front, **where data lives** and **who owns backup** — because
"data in the git repo" is a run-from-source pattern that breaks the moment the app
is packaged (an installed `.app` has no checkout and its `app.asar` is read-only).

What this app persists, and where:

- **Settings** — `userData/settings.json` (grill name/model, targets, pellet
  calibration, maintenance counters, cook names).
- **Cook history** — `userData/cooks/*.jsonl`, one file per cook.

Both already live under `app.getPath('userData')` — never in the repo or the
bundle — so the packaging dead-end is avoided. The **app name is pinned**
(`openkb-pitboss-controller` in both `npm run dev` and the packaged `productName`),
so dev and the installed app share **one** store rather than splitting into two.

The open question the standing expectation forces: **does this data warrant an
app-managed backup** (the git-over-SSH snapshot pattern)?

## Decision

**Local-only storage, no cloud/remote backup in v1.**

A grill controller's cook history is **convenience data, not records** — a log of
past cooks and a pellet estimate. Losing it is mildly annoying, not costly or
irrecoverable, and there is no multi-user or compliance dimension. The
snapshot-sync pattern (deterministic export → commit → `git push` to a separate
data repo) is aimed at apps where data loss is expensive (permits, business
records); applying it here would be overhead without a matching risk.

Concretely:

- Data stays in `userData` (already the case); nothing is written into the repo or
  bundle.
- The app name stays pinned so the store doesn't split across dev/packaged.
- No automatic backup is shipped. A user who wants a backup can copy the
  `userData` folder (the reset in dev did exactly this — moved it aside, fully
  reversible).

## Consequences

- **Ships now** with no backup infrastructure to build, sign, or maintain.
- **Restore = copy the folder back** (or start fresh — the app rebuilds its store
  and re-runs the setup wizard). That is the whole recovery story, and it's
  legible.
- **Upgrade path is clear if the need appears** (e.g. wanting cook history on more
  than one machine): add a debounced git-over-SSH snapshot of a deterministic
  per-cook export to a *separate data repo*, per the standing expectation — a
  self-contained addition that doesn't require re-homing the live store.
- Satisfies the DoD "data storage & backup decided" bar by an explicit, recorded
  decision rather than by building unneeded machinery.
