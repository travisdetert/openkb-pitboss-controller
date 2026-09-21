// What "healthy" means for THIS project — the checks no generic runner could know.
// Consumed by `scripts/doctor.mjs` (npm run doctor). See openkb-claude-harness
// ADR-0006.
//
// Every check here answers a question that has actually bitten this project. None
// of them exist to produce a green tick.
import { existsSync, statSync, readdirSync } from 'node:fs'
import { join } from 'node:path'

/** Newest mtime under a directory tree, or 0. Cheap, no shelling out. */
function newest(dir, exts) {
  let out = 0
  const walk = (d) => {
    let ents
    // NOT require(): this file is ESM, so require is undefined here. It threw,
    // the catch swallowed it, and the walk returned 0 — which the checks below
    // faithfully reported as "no screenshots" and "no iOS sources" while six
    // PNGs and the whole Swift package sat on disk. A check that lies is worse
    // than no check.
    try { ents = readdirSync(d, { withFileTypes: true }) } catch { return }
    for (const e of ents) {
      const p = join(d, e.name)
      if (e.isDirectory()) { if (e.name !== '.build' && e.name !== 'node_modules') walk(p); continue }
      if (exts && !exts.some((x) => e.name.endsWith(x))) continue
      try { const m = statSync(p).mtimeMs; if (m > out) out = m } catch { /* raced */ }
    }
  }
  walk(dir)
  return out
}

export default {
  // The bundle a user installs. `tsc` passing says nothing about whether this
  // still packages — and it had not been built for two months while the code
  // moved underneath it.
  distributables: [
    {
      path: 'release/mac-arm64/openkb-pit-boss.app',
      label: 'macOS app bundle',
      build: 'npm run pack'
    }
  ],
  sourceRoots: ['src', 'python', 'data'],

  checks: [
    {
      id: 'sidecar-self-contained',
      label: 'Frozen sidecar has no escape hatches',
      // ADR-0005: the first packaging attempt shipped a venv, which is NOT
      // relocatable — it worked only on the dev machine, by borrowing its
      // Homebrew Python through a symlink that dangles anywhere else. That is
      // invisible until someone else runs the app, so check it here.
      async run({ sh, root }) {
        const bin = join(root, 'dist-sidecar/sidecar')
        if (!existsSync(bin))
          return { status: 'warn', detail: 'not built yet', fix: 'npm run build:sidecar' }
        const r = await sh('otool', ['-L', bin], { timeoutMs: 15000 })
        const bad = r.stdout.split('\n')
          .filter((l) => /\.venv|Python\.framework|\/opt\/homebrew.*[Pp]ython/.test(l))
        return bad.length
          ? { status: 'fail',
              detail: `links outside the bundle: ${bad.length} ref(s) — will not run on another Mac`,
              fix: 'npm run build:sidecar' }
          : { status: 'pass', detail: 'no external Python references' }
      }
    },
    {
      id: 'ios-conformance-current',
      label: 'iOS conformance re-run since the Swift changed',
      // The 1346 golden-vector checks are what keep the Swift port honest against
      // pytboss. They are worthless if nobody has run them since the last edit.
      async run({ root }) {
        const bin = join(root, 'ios/PitBossKit/.build/arm64-apple-macosx/debug/pitboss-verify')
        const src = newest(join(root, 'ios/PitBossKit/Sources'), ['.swift', '.json'])
        if (!src) return { status: 'skip', detail: 'no iOS sources found' }
        if (!existsSync(bin))
          return { status: 'warn', detail: 'never run on this machine', fix: 'npm run ios:verify' }
        const built = statSync(bin).mtimeMs
        return built >= src
          ? { status: 'pass', detail: 'verifier newer than every Swift source' }
          : { status: 'warn',
              detail: 'Swift changed since the vectors last ran',
              fix: 'npm run ios:verify' }
      }
    },
    {
      id: 'screenshots-current',
      label: 'Screenshots match the UI',
      // Docs-currency gate: a screenshot of a UI that no longer exists is a bug,
      // and this project has shipped one before.
      async run({ root }) {
        const shots = newest(join(root, 'docs/screenshots'), ['.png'])
        const ui = newest(join(root, 'src/renderer'), ['.ts', '.css', '.html'])
        if (!shots) return { status: 'warn', detail: 'none captured', fix: 'npm run screenshots' }
        return shots >= ui
          ? { status: 'pass', detail: 'newer than every renderer source' }
          : { status: 'warn', detail: 'renderer changed since last capture', fix: 'npm run screenshots' }
      }
    },
    {
      id: 'stop-script',
      label: 'Clean stop path exists',
      // A dev run left holding the Bluetooth connection blocks the next launch.
      async run({ sh }) {
        const pkg = JSON.parse((await sh('cat', ['package.json'])).stdout || '{}')
        return pkg.scripts?.stop
          ? { status: 'pass', detail: `npm run stop → ${pkg.scripts.stop}` }
          : { status: 'fail', detail: 'no stop script — risks orphaned Electron processes',
              fix: 'add a "stop" script' }
      }
    }
  ]
}
