#!/usr/bin/env node
// VENDORED from openkb-claude-harness/dashboard/scripts/doctor.mjs.
//
// Copied rather than referenced on purpose: the doctor's job is to answer "does
// this build right now?" on a FRESH CHECKOUT, and a script that reaches outside
// the repo — to an absolute path on one machine — fails exactly when it is most
// needed. It has zero runtime dependencies precisely so it can travel this way.
//
// The contract is `.health.json`'s schema, not this file, so a drift between
// copies is tolerable in a way a drift in the schema would not be. If you change
// behaviour here, change it at the source too.
// Project health check — the "doctor". A fast, run-often diagnostic (NOT the
// heavy ship-check release gate): it answers "does this build right now, and
// what's broken?" It runs standard stack-detected checks plus any project-
// specific checks declared in `health.config.mjs`, prints a human report, and
// writes a machine-readable `.health.json` the dashboard reads.
//
// Contract (the part other tools depend on): the `.health.json` SCHEMA below and
// the `npm run doctor` entrypoint. This Node runner is the reference
// implementation — a non-Node project may provide its own doctor that writes the
// same schema. Zero runtime dependencies by design.
//
// Usage: node scripts/doctor.mjs [--json] [--no-write] [--strict]
//   --json      print the JSON instead of the human report
//   --no-write  don't write .health.json (diagnose only)
//   --strict    exit non-zero on warn as well as fail (default: fail only)
import { promises as fs, existsSync, readFileSync } from 'node:fs'
import { execFile } from 'node:child_process'
import { join, dirname } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const args = new Set(process.argv.slice(2))
const OUT = join(ROOT, '.health.json')

// ---- status algebra -------------------------------------------------------
const RANK = { pass: 0, skip: 0, warn: 1, fail: 2 }
const worst = (a, b) => (RANK[b] > RANK[a] ? b : a)

// ---- a bounded shell helper handed to every check -------------------------
/** Run a command; resolves { code, stdout, stderr, timedOut } — never rejects. */
function sh(cmd, argv = [], { timeoutMs = 30000, cwd = ROOT } = {}) {
  return new Promise((resolve) => {
    const child = execFile(
      cmd,
      argv,
      { cwd, timeout: timeoutMs, windowsHide: true, maxBuffer: 8 * 1024 * 1024 },
      (err, stdout, stderr) => {
        resolve({
          code: err && typeof err.code === 'number' ? err.code : err ? 1 : 0,
          stdout: stdout ?? '',
          stderr: stderr ?? '',
          timedOut: !!(err && err.killed)
        })
      }
    )
    child.on('error', () => {}) // ENOENT etc. surface via the callback's err
  })
}

const onPath = async (bin) => (await sh('command', ['-v', bin], { timeoutMs: 4000 })).code === 0

function readPkg() {
  const p = join(ROOT, 'package.json')
  if (!existsSync(p)) return null
  try {
    return JSON.parse(readFileSync(p, 'utf8'))
  } catch {
    return null
  }
}

// ---- standard checks ------------------------------------------------------
// Each returns { id, label, status, detail, fix }. Detection is conservative:
// a check that doesn't apply to this stack returns `skip`, not a false pass.
async function checkDeps(pkg) {
  const id = 'deps'
  const label = 'Dependencies installed'
  if (!pkg) return { id, label, status: 'skip', detail: 'no package.json', fix: null }
  if (!existsSync(join(ROOT, 'node_modules'))) {
    return { id, label, status: 'fail', detail: 'node_modules is missing', fix: 'npm ci' }
  }
  // Lockfile present is the cheap "reproducible install" signal.
  const hasLock = ['package-lock.json', 'npm-shrinkwrap.json', 'yarn.lock', 'pnpm-lock.yaml'].some(
    (f) => existsSync(join(ROOT, f))
  )
  return hasLock
    ? { id, label, status: 'pass', detail: 'installed, lockfile present', fix: null }
    : { id, label, status: 'warn', detail: 'installed but no lockfile', fix: 'commit a lockfile' }
}

/** Pick the fastest "does it compile?" command for the stack. */
function buildCmd(pkg) {
  const s = (pkg && pkg.scripts) || {}
  if (s.typecheck) return ['npm', ['run', 'typecheck'], 'npm run typecheck']
  if (s['type-check']) return ['npm', ['run', 'type-check'], 'npm run type-check']
  if (existsSync(join(ROOT, 'tsconfig.json'))) return ['npx', ['tsc', '--noEmit'], 'tsc --noEmit']
  if (s.build) return ['npm', ['run', 'build'], 'npm run build']
  if (existsSync(join(ROOT, 'Cargo.toml'))) return ['cargo', ['check', '-q'], 'cargo check']
  if (existsSync(join(ROOT, 'go.mod'))) return ['go', ['build', './...'], 'go build ./...']
  return null
}

async function checkBuild(pkg, cfg) {
  const id = 'build'
  const label = 'Build / compile'
  if (cfg?.standard?.build?.enabled === false)
    return { id, label, status: 'skip', detail: 'disabled in health.config', fix: null }
  const picked = buildCmd(pkg)
  if (!picked) return { id, label, status: 'skip', detail: 'no compile step detected', fix: null }
  const [cmd, argv, human] = picked
  const r = await sh(cmd, argv, { timeoutMs: cfg?.standard?.build?.timeoutMs ?? 120000 })
  if (r.timedOut) return { id, label, status: 'warn', detail: `${human} timed out`, fix: null }
  return r.code === 0
    ? { id, label, status: 'pass', detail: `${human} clean`, fix: null }
    : { id, label, status: 'fail', detail: `${human} reported errors`, fix: human }
}

// ---- distributable freshness ----------------------------------------------
// `build` above compiles; it says nothing about whether the thing you SHIP still
// builds. For an app that ships a bundle — an Electron `.app`, an .ipa, a binary
// — a green `tsc` and a broken packaging step look identical, and the gap is
// only discovered at release.
//
// Actually packaging here would be wrong: `npm run pack` takes minutes, and the
// doctor's whole contract (ADR-0006) is a deterministic answer in a second or
// two. So this reports FRESHNESS, not success — is there an artifact, and is it
// newer than the newest source file? A stale artifact is the honest signal that
// what you last shipped no longer reflects the code. Building it for real is
// /ship-check's job.
//
// Declared, never guessed: a project lists its artifacts in health.config.mjs.
// Inferring "this looks like an Electron app so there should be a .app" would
// fail every project that deliberately doesn't ship one.
async function checkDistributables(cfg) {
  const id = 'distributable'
  const label = 'Shippable artifact is current'
  const decl = cfg?.distributables
  if (!Array.isArray(decl) || decl.length === 0)
    return { id, label, status: 'skip', detail: 'none declared in health.config', fix: null }

  // Newest mtime under the declared source roots, via git so build output,
  // node_modules and untracked scratch files cannot make everything look stale.
  const srcRoots = cfg?.sourceRoots ?? ['src']
  const r = await sh('git', ['ls-files', '-z', '--', ...srcRoots], { timeoutMs: 15000 })
  let newestSrc = 0
  let newestSrcFile = null
  for (const f of r.stdout.split('\0').filter(Boolean)) {
    try {
      const m = (await fs.stat(join(ROOT, f))).mtimeMs
      if (m > newestSrc) { newestSrc = m; newestSrcFile = f }
    } catch { /* deleted between ls-files and stat */ }
  }

  const missing = []
  const stale = []
  for (const d of decl) {
    const path = join(ROOT, d.path)
    if (!existsSync(path)) { missing.push(d.label ?? d.path); continue }
    let m
    try { m = (await fs.stat(path)).mtimeMs } catch { missing.push(d.label ?? d.path); continue }
    if (newestSrc && m < newestSrc) stale.push(d.label ?? d.path)
  }

  const build = decl.map((d) => d.build).filter(Boolean).join(' && ') || null
  if (missing.length)
    return {
      id, label, status: 'warn',
      detail: `never built: ${missing.join(', ')}`,
      fix: build
    }
  if (stale.length)
    return {
      id, label, status: 'warn',
      detail: `older than ${newestSrcFile}: ${stale.join(', ')}`,
      fix: build
    }
  return {
    id, label, status: 'pass',
    detail: `${decl.length} artifact(s) newer than every tracked source file`,
    fix: null
  }
}

async function checkLint(pkg, cfg) {
  const id = 'lint'
  const label = 'Lint'
  if (cfg?.standard?.lint?.enabled === false)
    return { id, label, status: 'skip', detail: 'disabled in health.config', fix: null }
  const s = (pkg && pkg.scripts) || {}
  let cmd, argv, human
  if (s.lint) [cmd, argv, human] = ['npm', ['run', 'lint'], 'npm run lint']
  else if (existsSync(join(ROOT, 'Cargo.toml')))
    [cmd, argv, human] = ['cargo', ['clippy', '-q'], 'cargo clippy']
  else return { id, label, status: 'skip', detail: 'no linter detected', fix: null }
  const r = await sh(cmd, argv, { timeoutMs: cfg?.standard?.lint?.timeoutMs ?? 60000 })
  if (r.timedOut) return { id, label, status: 'warn', detail: `${human} timed out`, fix: null }
  return r.code === 0
    ? { id, label, status: 'pass', detail: `${human} clean`, fix: null }
    : { id, label, status: 'fail', detail: `${human} reported problems`, fix: human }
}

const PLACEHOLDER_TEST = /no test specified/
async function checkTests(pkg, cfg) {
  const id = 'tests'
  const label = 'Tests'
  if (cfg?.standard?.tests?.enabled === false)
    return { id, label, status: 'skip', detail: 'disabled in health.config', fix: null }
  const s = (pkg && pkg.scripts) || {}
  let cmd, argv, human
  if (s.test && !PLACEHOLDER_TEST.test(s.test)) [cmd, argv, human] = ['npm', ['test'], 'npm test']
  else if (existsSync(join(ROOT, 'Cargo.toml'))) [cmd, argv, human] = ['cargo', ['test', '-q'], 'cargo test']
  else if (existsSync(join(ROOT, 'go.mod'))) [cmd, argv, human] = ['go', ['test', './...'], 'go test ./...']
  else return { id, label, status: 'skip', detail: 'no test target', fix: null }
  const r = await sh(cmd, argv, { timeoutMs: cfg?.standard?.tests?.timeoutMs ?? 120000 })
  if (r.timedOut) return { id, label, status: 'warn', detail: `${human} timed out`, fix: null }
  return r.code === 0
    ? { id, label, status: 'pass', detail: `${human} passed`, fix: null }
    : { id, label, status: 'fail', detail: `${human} failed`, fix: human }
}

async function checkGit() {
  const id = 'git'
  const label = 'Git hygiene'
  if (!existsSync(join(ROOT, '.git'))) return { id, label, status: 'skip', detail: 'not a git repo', fix: null }
  const dirty = (await sh('git', ['-C', ROOT, 'status', '--porcelain'])).stdout.trim()
  const dirtyN = dirty ? dirty.split('\n').length : 0
  const hasRemote = (await sh('git', ['-C', ROOT, 'remote'])).stdout.trim() !== ''
  const notes = []
  let status = 'pass'
  if (dirtyN > 0) {
    notes.push(`${dirtyN} uncommitted`)
    status = worst(status, 'warn')
  }
  if (!hasRemote) {
    notes.push('no remote')
    status = worst(status, 'warn')
  } else {
    const url = (await sh('git', ['-C', ROOT, 'remote', 'get-url', 'origin'])).stdout.trim()
    if (/^https?:\/\//.test(url)) {
      notes.push('remote on HTTPS (SSH preferred)')
      status = worst(status, 'warn')
    }
  }
  return {
    id,
    label,
    status,
    detail: notes.length ? notes.join(' · ') : 'clean & backed up',
    fix: dirtyN > 0 ? 'commit or stash, then push' : hasRemote ? null : 'git remote add origin <ssh-url>'
  }
}

async function checkTooling() {
  const id = 'tooling'
  const label = 'Security scanners installed'
  const want = ['gitleaks', 'osv-scanner', 'semgrep']
  const missing = []
  for (const b of want) if (!(await onPath(b))) missing.push(b)
  return missing.length === 0
    ? { id, label, status: 'pass', detail: 'gitleaks · osv-scanner · semgrep', fix: null }
    : {
        id,
        label,
        status: 'warn',
        detail: `missing: ${missing.join(', ')}`,
        fix: `brew install ${missing.join(' ')}`
      }
}

// ---- config (project-specific custom checks) ------------------------------
async function loadConfig() {
  const p = join(ROOT, 'health.config.mjs')
  if (!existsSync(p)) return {}
  try {
    const mod = await import(pathToFileURL(p).href)
    return mod.default ?? {}
  } catch (e) {
    console.error(`[doctor] failed to load health.config.mjs: ${e.message}`)
    return {}
  }
}

async function runCustom(cfg) {
  const list = Array.isArray(cfg.checks) ? cfg.checks : []
  const ctx = { sh, root: ROOT, onPath }
  const out = []
  for (const c of list) {
    const base = { id: c.id ?? 'custom', label: c.label ?? c.id ?? 'Custom check' }
    if (typeof c.run !== 'function') {
      out.push({ ...base, status: 'skip', detail: 'no run() defined', fix: null })
      continue
    }
    try {
      const timeoutMs = c.timeoutMs ?? 30000
      const res = await Promise.race([
        Promise.resolve(c.run(ctx)),
        new Promise((r) => setTimeout(() => r({ status: 'warn', detail: 'check timed out' }), timeoutMs))
      ])
      out.push({
        ...base,
        status: RANK[res?.status] != null ? res.status : 'warn',
        detail: res?.detail ?? '',
        fix: res?.fix ?? null
      })
    } catch (e) {
      out.push({ ...base, status: 'fail', detail: `threw: ${e.message}`, fix: null })
    }
  }
  return out
}

// ---- main -----------------------------------------------------------------
async function main() {
  const started = Date.now()
  const pkg = readPkg()
  const cfg = await loadConfig()

  const standard = [
    await checkDeps(pkg),
    await checkBuild(pkg, cfg),
    await checkLint(pkg, cfg),
    await checkTests(pkg, cfg),
    await checkDistributables(cfg),
    await checkGit(),
    await checkTooling()
  ]
  const custom = await runCustom(cfg)
  const checks = [...standard, ...custom]

  const overall = checks.reduce((acc, c) => worst(acc, c.status), 'pass')
  const commit = (await sh('git', ['-C', ROOT, 'rev-parse', '--short', 'HEAD'])).stdout.trim() || null

  const report = {
    schema: 1,
    status: overall,
    generatedAt: new Date().toISOString(),
    commit,
    durationMs: Date.now() - started,
    checks
  }

  if (!args.has('--no-write')) {
    await fs.writeFile(OUT, JSON.stringify(report, null, 2) + '\n')
  }

  if (args.has('--json')) {
    console.log(JSON.stringify(report, null, 2))
  } else {
    printReport(report)
  }

  const bad = overall === 'fail' || (args.has('--strict') && overall === 'warn')
  process.exit(bad ? 1 : 0)
}

const GLYPH = { pass: '✓', warn: '⚠', fail: '✗', skip: '–' }
function printReport(r) {
  const head = { pass: 'HEALTHY', warn: 'WARNINGS', fail: 'UNHEALTHY' }[r.status]
  console.log(`\nDoctor — ${head}  (${r.durationMs}ms${r.commit ? `, @${r.commit}` : ''})\n`)
  for (const c of r.checks) {
    if (c.status === 'skip') continue
    console.log(`  ${GLYPH[c.status]} ${c.label}: ${c.detail}`)
    if (c.fix && c.status !== 'pass') console.log(`      ↳ fix: ${c.fix}`)
  }
  const skipped = r.checks.filter((c) => c.status === 'skip')
  if (skipped.length) console.log(`\n  (skipped: ${skipped.map((c) => c.id).join(', ')})`)
  // Report what actually happened: printReport runs under --no-write too, and
  // claiming a write that was skipped is the tool lying about its own effect.
  console.log(args.has('--no-write') ? `\n  → --no-write: .health.json not written\n`
                                     : `\n  → wrote .health.json\n`)
}

main().catch((e) => {
  console.error(`[doctor] fatal: ${e.stack || e.message}`)
  process.exit(1)
})
