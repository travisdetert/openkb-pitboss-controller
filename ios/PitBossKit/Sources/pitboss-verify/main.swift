import Foundation
import PitBossKit

/// Conformance checks for the Swift port of the Pit Boss BLE protocol.
///
/// The golden vectors in `vectors.json` are produced by running pytboss's own
/// codec/command/parse routines (ios/Tools/generate-vectors.py). The bar these
/// checks hold is therefore "the Swift port behaves exactly like the library
/// the desktop app already trusts", not "the port matches my reading of the
/// protocol". Regenerate the vectors whenever pytboss is upgraded.

struct Vectors: Decodable {
    struct Command: Decodable { let args: [Int]; let hex: String }
    struct Frame: Decodable { let message: String; let state: [String: JSONValue] }
    struct Length: Decodable { let n: Int; let bytes: [UInt8] }
    struct TimedKey: Decodable { let uptime: Double; let key: [UInt8] }
    struct DecodeVector: Decodable {
        let plaintextHex: String; let encodedHex: String; let decodedHex: String
    }
    let commands: [String: Command]
    let temperatureFrames: [Frame]
    let statusFrames: [Frame]
    let rejectedFrames: [String]
    let lengthFraming: [Length]
    let timedKeys: [TimedKey]
    let decodeVectors: [DecodeVector]
}

/// Projects a GrillState back into the vectors' key space for comparison.
func mirror(_ s: GrillState) -> [String: JSONValue] {
    var out: [String: JSONValue] = [:]
    func b(_ k: String, _ v: Bool?) { if let v { out[k] = .bool(v) } }
    func i(_ k: String, _ v: Int?) { if let v { out[k] = .int(v) } }
    b("moduleIsOn", s.moduleIsOn)
    b("err1", s.err1); b("err2", s.err2); b("err3", s.err3)
    b("highTempErr", s.highTempErr); b("fanErr", s.fanErr); b("hotErr", s.hotErr)
    b("motorErr", s.motorErr); b("noPellets", s.noPellets); b("erL", s.erL)
    b("fanState", s.fanState); b("hotState", s.hotState); b("motorState", s.motorState)
    b("lightState", s.lightState); b("primeState", s.primeState)
    b("isFahrenheit", s.isFahrenheit)
    i("recipeStep", s.recipeStep); i("recipeTime", s.recipeTime)
    i("p1Target", s.p1Target); i("p1Temp", s.p1Temp); i("p2Temp", s.p2Temp)
    i("p3Temp", s.p3Temp); i("p4Temp", s.p4Temp)
    i("grillSetTemp", s.grillSetTemp); i("grillTemp", s.grillTemp)
    i("smokerActTemp", s.smokerActTemp)
    return out
}

func XCTUnwrapProfile(_ p: BoardProfile?, _ h: Harness) throws -> BoardProfile {
    guard let p else { h.check(false, "expected a board profile"); throw ControlBoardError.notImplemented("profile") }
    return p
}

/// `--export-cooking <path>` dumps the catalogue to JSON and exits.
///
/// Exported *from* the Swift literals rather than hand-written, so the first
/// version of the shared file is guaranteed to be exactly what the app already
/// ships and passes its checks against (ADR 0007).
func exportCookingIfRequested() {
    let args = CommandLine.arguments
    guard let i = args.firstIndex(of: "--export-cooking"), i + 1 < args.count else { return }
    let path = args[i + 1]

    func targetJSON(_ t: MeatTarget) -> [String: Any] {
        ["label": t.label, "temperature": t.temperature, "kind": t.kind.rawValue]
    }
    func stepJSON(_ s: MethodStep) -> [String: Any] {
        var out: [String: Any] = ["title": s.title, "detail": s.detail]
        if let m = s.minutes { out["minutes"] = m }
        if let g = s.grillTemp { out["grillTemp"] = g }
        return out
    }
    func methodJSON(_ m: CookMethod) -> [String: Any] {
        var out: [String: Any] = ["name": m.name, "summary": m.summary,
                                  "steps": m.steps.map(stepJSON)]
        if let g = m.grillTemp { out["grillTemp"] = g }
        if let n = m.note { out["note"] = n }
        return out
    }
    func cutJSON(_ c: MeatCut) -> [String: Any] {
        var out: [String: Any] = [
            "name": c.name,
            "category": c.category.rawValue,
            "targets": c.targets.map(targetJSON),
            "methods": c.methods.map(\.name),
        ]
        if let n = c.note { out["note"] = n }
        if let g = c.grillTemp { out["grillTemp"] = g }
        if let f = c.safeFloorOverride { out["safeFloorOverride"] = f }
        return out
    }

    let root: [String: Any] = [
        "version": 1,
        "note": "Shared cooking knowledge for the iOS and desktop apps. See docs/adr/0007. Safety floors are USDA FSIS figures; do not edit without reading ADR 0009.",
        "safeMinimums": Dictionary(uniqueKeysWithValues:
            MeatCategory.allCases.compactMap { c in
                MeatCatalog.safeMinimum(for: c).map { (c.rawValue, $0) } }),
        "methods": MeatCatalog.methods.map(methodJSON),
        "cuts": MeatCatalog.cuts.map(cutJSON),
    ]

    let data = try! JSONSerialization.data(withJSONObject: root,
                                           options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) — \(MeatCatalog.cuts.count) cuts, \(MeatCatalog.methods.count) methods")
    exit(0)
}

exportCookingIfRequested()

// MARK: - Setup

let h = Harness()

guard let url = Bundle.module.url(forResource: "vectors", withExtension: "json"),
      let data = try? Data(contentsOf: url) else {
    FileHandle.standardError.write(
        Data("vectors.json missing — run: .venv/bin/python ios/Tools/generate-vectors.py\n".utf8))
    exit(2)
}
let vectors = try JSONDecoder().decode(Vectors.self, from: data)
let catalog = try GrillCatalog.bundled()
let board = try catalog.grill(named: "PB1100PSC3").controlBoard

print("PitBossKit conformance — \(catalog.count) grill models, board \(board.name)")

// MARK: - Catalogue

h.section("Catalogue")
h.check(catalog.count > 100, "expected the full Pit Boss catalogue, got \(catalog.count)")
for name in ["PBV30DS", "LG1200BL", "PBX - test 1"] {
    h.throwsError("unsupported model \(name) must not load") { try catalog.grill(named: name) }
}
do {
    let g = try catalog.grill(named: "PB1100PSC3")
    h.equal(g.controlBoard.name, "PBL", "control board")
    h.equal(g.minTemp, 180, "min temp")
    h.equal(g.maxTemp, 500, "max temp")
    h.equal(g.meatProbes, 2, "meat probes")
    h.equal(g.hasLights, false, "has lights")
    h.equal(g.tempIncrements, [180, 200, 225, 250, 300, 350, 400, 450, 475, 500], "increments")
}

// Every board must build its core command and survive a parse under
// JavaScriptCore. A model whose JS fails would be a silent dead end for that
// grill's owner, so all of them are exercised, not just the dev's.
// The presets a PBL owner actually has. Pinned because an earlier intersection
// silently dropped 225/450/475/500 — real setpoints on a PB1100PSC3.
do {
    let pbl = try XCTUnwrapProfile(catalog.profile(forBoard: "PBL"), h)
    for temp in [180, 200, 225, 250, 300, 350, 400, 450, 475, 500] {
        h.check(pbl.presets.contains(temp), "PBL presets include \(temp)°")
    }
    h.check(pbl.presets.allSatisfy { $0 >= pbl.minTemp && $0 <= pbl.maxTemp },
            "no preset falls outside the board's range")
    h.check(!pbl.presets.contains(130), "PBV4PS2's 130° is clipped out of the PBL range")
    h.equal(pbl.presets, pbl.presets.sorted(), "presets are ordered")
    h.equal(Set(pbl.presets).count, pbl.presets.count, "presets are unique")
    // The 130-420 vertical smoker on this board must not pollute the picker.
    for stray in [310, 320, 330, 340, 360, 370, 380, 390, 410, 420] {
        h.check(!pbl.presets.contains(stray),
                "PBL presets exclude \(stray)° (from the out-of-range PBV4PS2)")
    }
    print("  PBL presets: \(pbl.presets.map(String.init).joined(separator: ", "))")

    // Pinned exactly: this is the ladder docs/test-plan.md E1 records the PBL
    // firmware using (note 275 is absent — it skips 250→300).
    h.equal(pbl.presets, [180, 200, 225, 250, 300, 350, 400, 450, 475, 500],
            "PBL defaults to the firmware-verified 10-step ladder")
    h.check(!pbl.presets.contains(275), "275 stays absent — the firmware skips it")

    // Both of the board's ladders are offered for correction, shortest first.
    h.equal(pbl.ladderOptions.count, 2, "PBL has two distinct ladders to choose between")
    h.equal(pbl.ladderOptions.first, pbl.presets, "the default is the shortest option")
    h.check(pbl.ladderOptions[1].count > pbl.ladderOptions[0].count, "options are shortest-first")
    h.check(pbl.ladderOptions.allSatisfy { ladder in
                ladder.allSatisfy { $0 >= pbl.minTemp && $0 <= pbl.maxTemp } },
            "no option strays outside the board's range")

    // Every board offers at least one usable ladder — an empty picker would be
    // a dead end for that grill's owner.
    for board in Set(catalog.allGrills().map(\.controlBoard.name)) {
        if let profile = catalog.profile(forBoard: board) {
            h.check(!profile.presets.isEmpty, "\(board) offers at least one setpoint")
            h.check(!profile.ladderOptions.isEmpty, "\(board) offers at least one ladder option")
        }
    }
}

h.section("Every control board runs under JavaScriptCore")
var boardsChecked = 0
for grill in catalog.allGrills() {
    let b = grill.controlBoard
    h.noThrow("get-status on \(grill.name)") { try b.command("get-status") }
    if b.commands["set-temperature"] != nil {
        h.noThrow("set-temperature on \(grill.name)") { try b.command("set-temperature", [225]) }
    }
    h.noThrow("status parse on \(grill.name)") { try b.parseStatus("FE0B00") }
    boardsChecked += 1
}
h.check(boardsChecked > 100, "expected >100 models exercised, got \(boardsChecked)")
print("  exercised \(boardsChecked) models")

// MARK: - Commands

h.section("Commands match pytboss")
for (label, expected) in vectors.commands.sorted(by: { $0.key < $1.key }) {
    let slug = label.contains("(") ? String(label.prefix(upTo: label.firstIndex(of: "(")!)) : label
    do {
        h.equal(try board.command(slug, expected.args), expected.hex, "command \(label)")
    } catch {
        h.check(false, "command \(label) threw \(error)")
    }
}
h.throwsError("unknown command must throw") { try board.command("launch-the-grill") }

// MARK: - Frame parsing

h.section("Frame parsing matches pytboss")

func compare(_ parsed: ParsedFrame, _ expected: [String: JSONValue], _ frame: String) {
    // The keys pytboss reported must be exactly the keys we report — that is
    // what keeps "probe unplugged" distinct from "field not in this frame".
    h.equal(parsed.reportedKeys, Set(expected.keys), "reported keys for \(frame.prefix(12))…")
    let actual = mirror(parsed.state)
    for (key, want) in expected.sorted(by: { $0.key < $1.key }) {
        h.equal(actual[key] ?? .null, want, "field \(key) in \(frame.prefix(12))…")
    }
}

for frame in vectors.temperatureFrames {
    if let parsed = h.notNil(try board.parseTemperatures(frame.message), "parse \(frame.message.prefix(12))…") {
        compare(parsed, frame.state, frame.message)
    }
}
for frame in vectors.statusFrames {
    if let parsed = h.notNil(try board.parseStatus(frame.message), "parse \(frame.message.prefix(12))…") {
        compare(parsed, frame.state, frame.message)
    }
}
for message in vectors.rejectedFrames {
    h.isNil(try board.parseStatus(message), "status should reject '\(message)'")
    h.isNil(try board.parseTemperatures(message), "temps should reject '\(message)'")
}

// An unplugged probe reads 960, which the board maps to null. That has to
// surface as "reported, but nil" so the UI blanks the reading instead of
// freezing the last one.
if let parsed = try board.parseTemperatures(vectors.temperatureFrames[0].message) {
    h.check(parsed.reportedKeys.contains("p2Temp"), "unplugged probe is still a reported key")
    h.isNil(parsed.state.p2Temp, "unplugged probe reads nil")
}

// MARK: - RPC framing

h.section("RPC framing")
for c in vectors.lengthFraming {
    h.equal(RPCFraming.encodeLength(c.n), c.bytes, "encode length \(c.n)")
    h.equal(RPCFraming.decodeLength(c.bytes), c.n, "decode length \(c.n)")
}
let chunks = RPCFraming.chunk([UInt8](repeating: 0x41, count: 45))
h.equal(chunks.map(\.count), [20, 20, 5], "20-byte chunking")
h.equal(chunks.flatMap { $0 }, [UInt8](repeating: 0x41, count: 45), "chunks reassemble")
h.check(RPCFraming.chunk([]).isEmpty, "empty payload yields no chunks")

// MARK: - Codec

h.section("Password codec")
for c in vectors.timedKeys {
    h.equal(Codec.timedKey(uptime: c.uptime), c.key, "timed key at uptime \(c.uptime)")
}
for v in vectors.decodeVectors {
    h.equal(Codec.decode([UInt8](hex: v.encodedHex)).hexString, v.decodedHex, "decode \(v.plaintextHex)")
    h.equal(v.decodedHex, v.plaintextHex, "vector round-trips in pytboss")
}
for text in ["", "a", "hunter2", "a longer grill password 12345"] {
    let bytes = Array(text.utf8)
    h.equal(Codec.decode(Codec.encode(bytes)), bytes, "round trip '\(text)'")
}
// Random padding means two encodings of one password must differ.
h.check(Codec.encode(Array("hunter2".utf8)) != Codec.encode(Array("hunter2".utf8)),
        "encoding is salted")

// MARK: - Debug frames

h.section("Debug-log frames")
let tempPayload = vectors.temperatureFrames[0].message
let statusPayload = vectors.statusFrames[0].message
h.equal(DebugFrame.parse("<==PB: \(tempPayload) (\(tempPayload.count))")?.kind, .temperatures, "FE0C frame")
h.equal(DebugFrame.parse("<==PB: \(statusPayload) (\(statusPayload.count))")?.kind, .status, "FE0B frame")
h.equal(DebugFrame.parse("<==PBD: ABCD (4)")?.kind, .virtualData, "virtual-data frame")
h.isNil(DebugFrame.parse("<==PB: \(tempPayload) (3)"), "bad checksum is dropped")
h.isNil(DebugFrame.parse("<==PB: \(tempPayload)"), "short line is dropped")
h.isNil(DebugFrame.parse("something else entirely"), "unrelated chatter is dropped")

// MARK: - State merge

h.section("State merge")
if let temps = try board.parseTemperatures(tempPayload),
   let status = try board.parseStatus(statusPayload) {
    let merged = GrillState()
        .merged(with: temps.state, reportedKeys: temps.reportedKeys)
        .merged(with: status.state, reportedKeys: status.reportedKeys)
    // Temperatures must survive a status frame, which never mentions them.
    h.equal(merged.grillTemp, 231, "grill temp survives the status frame")
    h.equal(merged.p1Target, 145, "probe target survives the status frame")
    h.equal(merged.motorState, true, "auger state lands from the status frame")
    h.equal(merged.recipeTime, 5415, "recipe time (1h30m15s)")
    h.equal(merged.hasError, false, "clean frame reports no error")
}
if let frame = vectors.statusFrames.first(where: { $0.state["noPellets"] == .bool(true) }),
   let parsed = try board.parseStatus(frame.message) {
    h.check(parsed.state.hasError, "out-of-pellets raises hasError")
}

// MARK: - Reconnect policy

h.section("Reconnect backoff")
let policy = ReconnectPolicy.standard
// Matches the desktop sidecar's _reconnect_loop: 3s, doubling, capped at 30s.
h.equal(policy.ladder(8), [3, 6, 12, 24, 30, 30, 30, 30], "standard backoff ladder")
h.equal(policy.delay(forAttempt: 1), 3, "first retry is immediate-ish")
h.equal(policy.delay(forAttempt: 99), 30, "never backs off past the cap")
h.check(policy.ladder(6).allSatisfy { $0 <= 30 },
        "a cook out of range rejoins within 30s of returning")
// Degenerate inputs must not produce a zero or shrinking delay, which would
// turn a dropped link into a tight reconnect loop against the radio.
let silly = ReconnectPolicy(initialDelay: 0, maximumDelay: -5, multiplier: 0)
h.check(silly.delay(forAttempt: 1) >= 1, "initial delay is never below 1s")
h.check(silly.ladder(5).allSatisfy { $0 >= 1 }, "no zero-delay retries")
h.check(zip(policy.ladder(6), policy.ladder(6).dropFirst()).allSatisfy { $0 <= $1 },
        "delays never shrink")

// MARK: Remembered radio
//
// The ladder above is now only the backstop. The real recovery is the standing
// `central.connect`, which the system completes even while the app is
// suspended — and the fast path into it is the remembered peripheral id.
//
// This is what made every retry cost a ten-second scan: the old lookup used
// `retrieveConnectedPeripherals`, which by definition returns nothing for a
// peripheral that has just disconnected, so the fast path never once applied
// in the case it existed for.
do {
    let name = "PBL-VERIFYTEST"
    let defaults = UserDefaults.standard
    let key = "pitboss.knownPeripherals"
    let saved = defaults.dictionary(forKey: key)
    defer { defaults.set(saved, forKey: key) }
    defaults.removeObject(forKey: key)

    h.isNil(BLETransport.rememberedPeripheral(forName: name),
            "an unseen grill has no remembered radio")

    let id = UUID()
    BLETransport.rememberPeripheral(id, forName: name)
    h.equal(BLETransport.rememberedPeripheral(forName: name), id,
            "the radio is remembered, so a reconnect skips the scan")

    // Survives a rewrite with the same value (the connect path writes on every
    // successful link) and updates when the radio genuinely changes.
    BLETransport.rememberPeripheral(id, forName: name)
    h.equal(BLETransport.rememberedPeripheral(forName: name), id,
            "re-remembering the same radio is a no-op")
    let replacement = UUID()
    BLETransport.rememberPeripheral(replacement, forName: name)
    h.equal(BLETransport.rememberedPeripheral(forName: name), replacement,
            "a replaced controller board overwrites the old radio")

    // Two grills must not share a slot.
    BLETransport.rememberPeripheral(id, forName: "PBL-OTHER")
    h.equal(BLETransport.rememberedPeripheral(forName: name), replacement,
            "remembering another grill leaves this one alone")
}

// MARK: - Graceful shutdown

// These are the assertions from scripts/test-shutdown.mjs, ported case for
// case. The thresholds were validated on the real grill (2026-07-16); this is
// the feature that exists because a burnback seized the auger motor, so the
// Swift machine is held to exactly the desktop's behaviour.
h.section("Graceful shutdown (ported from scripts/test-shutdown.mjs)")

func input(_ on: Bool, _ temp: Int?, _ set: Int?, _ fan: Bool) -> ShutdownInput {
    ShutdownInput(moduleIsOn: on, grillTemp: temp, grillSetTemp: set, fanState: fan)
}

// begin: hot grill ramps down first
var step = Shutdown.begin(input(true, 450, 450, true))
h.equal(step.phase, .cooling, "begin hot -> cooling")
h.equal(step.action, .cool, "begin hot -> action cool")
h.check(step.notice != nil, "begin hot -> has notice")

// begin: already-cool grill powers off immediately
step = Shutdown.begin(input(true, 190, 225, true))
h.equal(step.phase, .finishing, "begin cool -> finishing")
h.equal(step.action, .off, "begin cool -> action off")

// begin: grill already off -> off path
step = Shutdown.begin(input(false, nil, nil, false))
h.equal(step.action, .off, "begin off -> action off")

// A grill exactly at the threshold must NOT skip the cool-down.
step = Shutdown.begin(input(true, 250, 250, true))
h.equal(step.action, .off, "begin at coolAbove exactly -> off (strictly greater cools)")
step = Shutdown.begin(input(true, 251, 251, true))
h.equal(step.action, .cool, "begin just above coolAbove -> cool")

// advance cooling: still hot -> stay cooling
step = Shutdown.advance(.cooling, input(true, 300, 200, true))
h.equal(step.phase, .cooling, "cooling@300 -> stay cooling")
h.equal(step.action, nil, "cooling@300 -> no action")

// advance cooling: reached cool target -> off
step = Shutdown.advance(.cooling, input(true, 205, 200, true))
h.equal(step.phase, .finishing, "cooling@205 -> finishing")
h.equal(step.action, .off, "cooling@205 -> action off")

// advance finishing: fan still running -> stay
step = Shutdown.advance(.finishing, input(false, 180, 200, true))
h.equal(step.phase, .finishing, "finishing + fan on -> stay")
h.equal(step.action, nil, "finishing + fan on -> no action")

// advance finishing: fully off -> done
step = Shutdown.advance(.finishing, input(false, 120, 200, false))
h.equal(step.phase, nil, "finishing + fully off -> done")
h.equal(step.action, nil, "finishing + fully off -> no action")
h.check(step.notice == nil, "finishing + fully off -> silent (recorder announces)")

// A missing temperature reading must never be read as "cool enough to cut power".
step = Shutdown.advance(.cooling, input(true, nil, 200, true))
h.equal(step.phase, .cooling, "cooling with no reading -> keep cooling, never power off blind")

// cool progress
h.equal(Shutdown.coolProgress(from: 450, current: 450), 0, "progress start ~0")
h.check(abs(Shutdown.coolProgress(from: 400, current: 300) - 0.5) < 0.01, "progress midway ~0.5")
h.equal(Shutdown.coolProgress(from: 400, current: 200), 1, "progress done clamps to 1")
h.equal(Shutdown.coolProgress(from: 400, current: 180), 1, "progress below target clamps to 1")
h.equal(Shutdown.coolProgress(from: 200, current: 300), 1, "degenerate span clamps to 1")

// The full cool -> off -> done run, driven as the controller drives it.
var phase: ShutdownPhase? = Shutdown.begin(input(true, 400, 400, true)).phase
var offSent = false
for temp in [380, 340, 300, 260, 220, 208] {
    let s = Shutdown.advance(phase, input(true, temp, 200, true))
    if s.action == .off { offSent = true }
    phase = s.phase
}
h.check(offSent, "a full cool-down run sends off exactly once it is cool")
h.equal(phase, .finishing, "run ends in finishing, waiting on the fan")
phase = Shutdown.advance(phase, input(false, 150, 200, false)).phase
h.equal(phase, nil, "machine completes when the module is off and the fan stopped")

// MARK: - Cook history

h.section("Cook history recording")

func makeState(on: Bool = true, grill: Int? = 225, set: Int? = 250,
               p1: Int? = nil, auger: Bool = false, fan: Bool = false,
               igniter: Bool = false) -> GrillState {
    var st = GrillState()
    st.moduleIsOn = on
    st.grillTemp = grill
    st.grillSetTemp = set
    st.p1Temp = p1
    st.motorState = auger
    st.fanState = fan
    st.hotState = igniter
    return st
}

do {
    let history = CookHistory()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // First update records; anything inside the 5s window does not.
    h.check(history.record(makeState(), now: t0), "first update records a sample")
    h.check(!history.record(makeState(), now: t0.addingTimeInterval(1)), "1s later is throttled")
    h.check(!history.record(makeState(), now: t0.addingTimeInterval(4.9)), "4.9s later is throttled")
    h.check(history.record(makeState(), now: t0.addingTimeInterval(5)), "5s later records")
    h.equal(history.samples.count, 2, "throttling keeps one point per interval")
}

do {
    // The load-bearing one: the auger pulses between samples. An instantaneous
    // read at the sample boundary would miss it entirely and the activity
    // timeline would show an idle grill that is actually feeding.
    let history = CookHistory()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    history.record(makeState(auger: false), now: t0)
    history.record(makeState(auger: true), now: t0.addingTimeInterval(1))   // throttled…
    history.record(makeState(auger: false), now: t0.addingTimeInterval(2))  // …and over
    history.record(makeState(auger: false), now: t0.addingTimeInterval(6))  // records

    h.check(history.samples.last?.auger == true,
            "a brief auger pulse between samples is latched, not lost")
    // And the latch must clear, or the timeline would show the auger stuck on.
    history.record(makeState(auger: false), now: t0.addingTimeInterval(12))
    h.check(history.samples.last?.auger == false, "latch clears after it is recorded")
}

do {
    // A fresh power-on starts a new curve so two cooks don't run together.
    let history = CookHistory()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    history.record(makeState(on: true, grill: 400), now: t0)
    history.record(makeState(on: true, grill: 390), now: t0.addingTimeInterval(5))
    h.equal(history.samples.count, 2, "two points recorded during the first cook")
    history.record(makeState(on: false, grill: 120), now: t0.addingTimeInterval(10))
    history.record(makeState(on: true, grill: 90), now: t0.addingTimeInterval(15))
    h.equal(history.samples.count, 1, "power-on clears the previous cook's curve")
}

do {
    let history = CookHistory()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    for i in 0..<6 {
        history.record(makeState(grill: 200 + i, p1: 100 + i, auger: i == 2 || i == 3),
                       now: t0.addingTimeInterval(Double(i) * 5))
    }
    h.equal(history.probesSeen, [1], "probe 1 is seen in the record")
    let augerRuns = history.runs(for: \.auger)
    h.equal(augerRuns.count, 1, "adjacent active samples make one run, not two")
    h.check(history.temperatureRange != nil, "a temperature range is derivable")
    if let r = history.temperatureRange {
        h.check(r.lowerBound < 100 && r.upperBound > 205, "range spans probes and grill")
        h.check(r.upperBound > r.lowerBound, "range is never inverted")
    }
    h.check(history.span != nil, "record has a time span")
}

do {
    // A flat line must not be rendered as a full-height band.
    let history = CookHistory()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    for i in 0..<3 { history.record(makeState(grill: 225, set: 225), now: t0.addingTimeInterval(Double(i) * 5)) }
    if let r = history.temperatureRange {
        h.check(r.upperBound - r.lowerBound >= 20, "a flat curve still gets a sane padded range")
    }
}

// MARK: - Cook persistence

h.section("Cook persistence")

do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pitboss-verify-cooks-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let scratch = UserDefaults(suiteName: "pitboss-verify-\(UUID().uuidString)")!
    let store = CookStore(directory: tmp, defaults: scratch)

    // File stems must be filename-safe, sortable, and match the desktop's.
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)  // fixed instant
    let stem = CookStore.fileStem(for: t0)
    h.check(CookStore.isValidID(stem), "generated stem '\(stem)' is a valid id")
    h.check(!stem.contains(":"), "stem has no colons (filename-safe)")

    // Path traversal must be refused before any path is built — an id becomes
    // a filename, and readCook/deleteCook are reachable from the UI.
    for bad in ["../../etc/passwd", "..", "", "2026-06-23T18:30:00",
                "2026-06-23T18-30-00/../x", "nope", "2026-6-3T1-3-0"] {
        h.check(!CookStore.isValidID(bad), "rejects id '\(bad)'")
        h.throwsError("readCook refuses '\(bad)'") { try store.readCook(bad) }
        h.throwsError("deleteCook refuses '\(bad)'") { try store.deleteCook(bad) }
    }

    // Round trip: write a cook, read it back.
    let id = store.startCook(at: t0, device: "PBL-TEST")
    for i in 0..<5 {
        store.append(CookSample(
            at: t0.addingTimeInterval(Double(i) * 5),
            grillTemp: 200 + i,
            grillSetTemp: 225,
            probes: [1: 140 + i, 2: 90 + i],
            auger: i == 2,
            fan: true,
            igniter: i == 0))
    }
    h.equal(store.activeCookID, id, "cook is active while recording")
    h.throwsError("cannot delete the cook still being written") { try store.deleteCook(id) }
    store.endCook(at: t0.addingTimeInterval(30))
    h.isNil(store.activeCookID, "no active cook after endCook")

    let read = (try? store.readCook(id)) ?? []
    h.equal(read.count, 5, "all samples survive the round trip")
    h.equal(read.first?.grillTemp, 200, "grill temp round-trips")
    h.equal(read.first?.grillSetTemp, 225, "setpoint round-trips")
    h.equal(read.first?.probes[1], 140, "probe 1 round-trips")
    h.equal(read.first?.probes[2], 90, "probe 2 round-trips")
    h.isNil(read.first?.probes[3], "an absent probe stays absent, not zero")
    h.equal(read[2].auger, true, "latched auger activity round-trips")
    h.equal(read.first?.igniter, true, "igniter round-trips")

    // Metadata.
    let cooks = store.listCooks()
    h.equal(cooks.count, 1, "the cook is listed")
    if let meta = cooks.first {
        h.equal(meta.id, id, "listed id matches")
        h.equal(meta.sampleCount, 5, "sample count from the file")
        h.equal(meta.device, "PBL-TEST", "device recorded in meta")
        h.check(meta.endedAt != nil, "ended cook has an end time")
        h.equal(meta.duration, 30, "duration derived from meta")
    }

    // Naming lives beside the data; renaming must not touch the samples.
    try? store.renameCook(id, to: "Brisket overnight")
    h.equal(store.listCooks().first?.name, "Brisket overnight", "cook can be named")
    h.equal((try? store.readCook(id))?.count, 5, "renaming does not disturb samples")
    try? store.renameCook(id, to: "   ")
    h.isNil(store.listCooks().first?.name, "a blank name clears it")

    // Newest first.
    let later = store.startCook(at: t0.addingTimeInterval(3600), device: nil)
    store.append(CookSample(at: t0.addingTimeInterval(3600), grillTemp: 180,
                            grillSetTemp: 180, probes: [:], auger: false, fan: false, igniter: false))
    store.endCook(at: t0.addingTimeInterval(3660))
    h.equal(store.listCooks().map(\.id), [later, id], "cooks list newest first")

    // Delete.
    try? store.deleteCook(id)
    h.equal(store.listCooks().count, 1, "deleted cook is gone")

    // Leave a file behind for the cross-implementation check below.
    // Explicit /tmp, not NSTemporaryDirectory(): the interop checker is a
    // separate Node process and must be able to find the file.
    let handoff = URL(fileURLWithPath: "/tmp/pitboss-interop.jsonl")
    if let data = try? Data(contentsOf: tmp.appendingPathComponent("\(later).jsonl")) {
        try? data.write(to: handoff)
    }
}

// MARK: - Probe targets

h.section("Probe targets & alerting")

func probeState(_ p1: Int?, _ p2: Int? = nil) -> GrillState {
    var st = GrillState()
    st.moduleIsOn = true
    st.p1Temp = p1
    st.p2Temp = p2
    return st
}

do {
    var targets = ProbeTargets.default
    h.equal(targets.target(for: 1), 145, "default probe 1 target matches the desktop")
    h.equal(targets.target(for: 2), 165, "default probe 2 target matches the desktop")
    h.equal(targets.label(for: 1), "Probe 1", "unnamed probe falls back to its number")
    targets.labels[1] = "Brisket"
    h.equal(targets.label(for: 1), "Brisket", "a named probe uses its name")
    targets.labels[2] = "   "
    h.equal(targets.label(for: 2), "Probe 2", "a blank name falls back, not to empty")
}

do {
    // Reaching the target fires once, not on every reading afterwards.
    var latches = ProbeAlerting.Latches()
    let targets = ProbeTargets(targets: [1: 145])

    h.equal(ProbeAlerting.evaluate(state: probeState(140), targets: targets, latches: &latches).count,
            0, "below target: silent")
    var events = ProbeAlerting.evaluate(state: probeState(145), targets: targets, latches: &latches)
    h.equal(events, [.reachedTarget(probe: 1, temperature: 145, target: 145)], "at target: fires once")
    h.equal(ProbeAlerting.evaluate(state: probeState(146), targets: targets, latches: &latches).count,
            0, "still at target: does not re-fire")
    h.equal(ProbeAlerting.evaluate(state: probeState(144), targets: targets, latches: &latches).count,
            0, "1° below: hysteresis holds the latch")

    // Only a real drop re-arms it.
    h.equal(ProbeAlerting.evaluate(state: probeState(142), targets: targets, latches: &latches).count,
            0, "re-arming is silent")
    events = ProbeAlerting.evaluate(state: probeState(145), targets: targets, latches: &latches)
    h.equal(events.count, 1, "after dropping well below, it can fire again")
}

do {
    // Over-target is a separate, louder event: the food is overcooking.
    var latches = ProbeAlerting.Latches()
    let targets = ProbeTargets(targets: [1: 145])
    _ = ProbeAlerting.evaluate(state: probeState(145), targets: targets, latches: &latches)
    h.equal(ProbeAlerting.evaluate(state: probeState(149), targets: targets, latches: &latches).count,
            0, "4° over: not yet an escalation")
    let events = ProbeAlerting.evaluate(state: probeState(150), targets: targets, latches: &latches)
    h.equal(events, [.overTarget(probe: 1, temperature: 150, target: 145)], "5° over escalates")
    h.equal(ProbeAlerting.evaluate(state: probeState(160), targets: targets, latches: &latches).count,
            0, "further over: does not spam")
}

do {
    // Every probe is watched, including ones no board can be told about.
    var latches = ProbeAlerting.Latches()
    let targets = ProbeTargets(targets: [1: 145, 2: 165])
    // Just over each target — far enough to be "reached", not far enough to
    // also escalate (150 would be exactly 5° over 145 and fire both).
    let events = ProbeAlerting.evaluate(state: probeState(146, 166), targets: targets, latches: &latches)
    h.equal(events.count, 2, "both probes alert independently")
    h.check(events.contains(.reachedTarget(probe: 2, temperature: 166, target: 165)),
            "probe 2 alerts even though PBL cannot be sent a probe-2 target")

    // And crossing the escalation line later fires exactly one more event each.
    let escalations = ProbeAlerting.evaluate(state: probeState(150, 170), targets: targets, latches: &latches)
    h.equal(escalations.count, 2, "both probes escalate once when 5° over")
    h.check(escalations.allSatisfy { if case .overTarget = $0 { return true }; return false },
            "escalations are over-target events, not repeats of reached")
}

do {
    // An unplugged probe reads nil and must never alert.
    var latches = ProbeAlerting.Latches()
    let targets = ProbeTargets(targets: [1: 145, 3: 200])
    h.equal(ProbeAlerting.evaluate(state: probeState(nil), targets: targets, latches: &latches).count,
            0, "an unplugged probe never alerts")
    // A zero or missing target means "not set", not "target of 0".
    var zeroed = ProbeTargets(targets: [1: 0])
    h.equal(ProbeAlerting.evaluate(state: probeState(200), targets: zeroed, latches: &latches).count,
            0, "a zero target is treated as unset")
    zeroed.targets[1] = nil
    h.equal(ProbeAlerting.evaluate(state: probeState(200), targets: zeroed, latches: &latches).count,
            0, "no target set means no alert")
}

do {
    // Which probes the board can actually be told about.
    let pbl = try catalog.grill(named: "PB1100PSC3").controlBoard
    h.check(pbl.commands["set-probe-1-temperature"] != nil, "PBL accepts a probe 1 target")
    h.check(pbl.commands["set-probe-2-temperature"] == nil,
            "PBL has no probe 2 target command — the app must not pretend otherwise")
}

// MARK: - Ladder inference

h.section("Ladder inference from grill behaviour")

do {
    let pblModels = catalog.allGrills(controlBoard: "PBL")
    h.equal(pblModels.count, 6, "PBL has 6 candidate models")
    let range = 180...500

    // Nothing observed: everything is still possible.
    h.equal(LadderInference.narrow(candidates: pblModels, observations: []).count, 6,
            "no observations narrows nothing")
    h.isNil(LadderInference.summary(candidates: pblModels, observations: []),
            "nothing to report before any observation")

    // 190 exists only on the fine ladder. Accepting it rules out the coarse pair.
    let accepted190 = [SetpointObservation(requested: 190, reported: 190)]
    let fineOnly = LadderInference.narrow(candidates: pblModels, observations: accepted190)
    h.check(fineOnly.count < 6, "accepting 190° eliminates models without it")
    h.check(!fineOnly.contains { $0.name == "PB1100PSC3" },
            "PB1100PSC3 has no 190° and is eliminated when 190 is accepted")

    // Refusing 190 is the opposite, and is the case for this project's grill.
    let refused190 = [SetpointObservation(requested: 190, reported: 200)]
    let coarseOnly = LadderInference.narrow(candidates: pblModels, observations: refused190)
    h.check(coarseOnly.contains { $0.name == "PB1100PSC3" },
            "PB1100PSC3 survives when 190° is refused")
    h.check(!coarseOnly.contains { $0.name == "PB850PS2" },
            "a fine-ladder model is eliminated when 190° is refused")

    // And the ladder that follows is the coarse one the grill actually has.
    let ladder = LadderInference.ladder(candidates: pblModels, observations: refused190, range: range)
    for temp in [180, 200, 225, 250, 300, 350, 400, 450, 475, 500] {
        h.check(ladder.contains(temp), "inferred ladder keeps \(temp)°")
    }
    h.check(!ladder.contains(190), "a refused setpoint is never offered again")
    h.check(!ladder.contains(210), "fine-ladder steps drop out once ruled out")

    // A setpoint the grill demonstrably took is real even if no model lists it.
    let odd = [SetpointObservation(requested: 275, reported: 275)]
    h.check(LadderInference.ladder(candidates: pblModels, observations: odd, range: range).contains(275),
            "an accepted setpoint is offered even when the catalogue lacks it")

    // Contradictory observations must not produce an empty picker.
    let contradictory = [SetpointObservation(requested: 225, reported: 225),
                         SetpointObservation(requested: 225, reported: 250)]
    h.check(!LadderInference.narrow(candidates: pblModels, observations: contradictory).isEmpty,
            "contradictions fall back rather than narrowing to nothing")

    h.check(LadderInference.summary(candidates: pblModels, observations: refused190) != nil,
            "a summary is produced once something is known")
}

do {
    // Persistence, per grill, one entry per requested value.
    let scratch = UserDefaults(suiteName: "pitboss-ladder-\(UUID().uuidString)")!
    let grill = "PBL-TEST"
    h.equal(LadderMemory.load(grill: grill, from: scratch).count, 0, "starts empty")
    _ = LadderMemory.record(SetpointObservation(requested: 190, reported: 200), grill: grill, to: scratch)
    _ = LadderMemory.record(SetpointObservation(requested: 225, reported: 225), grill: grill, to: scratch)
    h.equal(LadderMemory.load(grill: grill, from: scratch).count, 2, "observations accumulate")
    // A later answer supersedes an earlier one for the same setpoint.
    let after = LadderMemory.record(SetpointObservation(requested: 190, reported: 190), grill: grill, to: scratch)
    h.equal(after.count, 2, "re-observing a setpoint replaces rather than duplicates")
    h.check(after.first { $0.requested == 190 }?.accepted == true, "the newer answer wins")
    LadderMemory.clear(grill: grill, from: scratch)
    h.equal(LadderMemory.load(grill: grill, from: scratch).count, 0, "memory can be cleared")
}

// MARK: - Pellet estimate

h.section("Pellet estimate")

do {
    let full = PelletState.default
    h.equal(PelletEstimate.remainingPounds(full), 20, "a fresh hopper is full")
    h.equal(PelletEstimate.percent(full), 100, "a fresh hopper reads 100%")

    // One hour of auger run-time burns the feed rate, by definition.
    var burned = full
    burned.augerSeconds = 3600
    h.equal(PelletEstimate.remainingPounds(burned), 12, "1h of auger burns 8 lb")
    h.equal(PelletEstimate.percent(burned), 60, "…leaving 60%")

    // Never negative, however long it has run.
    var overrun = full
    overrun.augerSeconds = 3600 * 100
    h.equal(PelletEstimate.remainingPounds(overrun), 0, "cannot go below empty")
    h.equal(PelletEstimate.percent(overrun), 0, "percent floors at 0")

    // Levels match the desktop's bar thresholds.
    h.equal(PelletEstimate.level(percent: 100), .ok, "100% is ok")
    h.equal(PelletEstimate.level(percent: 41), .ok, "41% is ok")
    h.equal(PelletEstimate.level(percent: 40), .low, "40% is low")
    h.equal(PelletEstimate.level(percent: 16), .low, "16% is low")
    h.equal(PelletEstimate.level(percent: 15), .critical, "15% is critical")
    h.equal(PelletEstimate.level(percent: 0), .critical, "empty is critical")

    // A zero-capacity hopper must not divide by zero.
    let silly = PelletState(capacityLbs: 0, feedRateLbsPerHr: 8)
    h.equal(PelletEstimate.percent(silly), 0, "zero capacity reads 0%, not NaN")
    h.check(!PelletEstimate.percent(silly).isNaN, "percent is never NaN")
}

do {
    // Integration is clamped: a gap must not be counted as continuous feeding.
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    var state = PelletState.default
    state = PelletEstimate.advance(state, augerOn: true, since: t0, now: t0.addingTimeInterval(5))
    h.equal(state.augerSeconds, 5, "5s of auger counts as 5s")
    state = PelletEstimate.advance(state, augerOn: false, since: t0, now: t0.addingTimeInterval(5))
    h.equal(state.augerSeconds, 5, "auger off adds nothing")
    // An hour-long disconnection must add at most the clamp, not an hour.
    state = PelletEstimate.advance(state, augerOn: true, since: t0, now: t0.addingTimeInterval(3600))
    h.equal(state.augerSeconds, 15, "a long gap is clamped to 10s, not integrated whole")
}

do {
    // Refill and empty.
    var state = PelletState.default
    state.augerSeconds = 3600
    let refilled = PelletEstimate.refilled(state)
    h.equal(PelletEstimate.percent(refilled), 100, "refilling resets to full")
    h.check(refilled.refilledAt != nil, "refill is dated")

    let emptied = PelletEstimate.emptied(state)
    h.equal(PelletEstimate.percent(emptied), 0, "emptying reads 0%")
    h.isNil(emptied.refilledAt, "emptying clears the refill date")

    // A zero feed rate must not produce infinity or NaN.
    let noRate = PelletEstimate.emptied(PelletState(capacityLbs: 20, feedRateLbsPerHr: 0))
    h.check(noRate.augerSeconds.isFinite, "emptying with a zero feed rate stays finite")
}

do {
    // Hours-left from the recent duty cycle.
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func sample(_ offset: Double, auger: Bool) -> CookSample {
        CookSample(at: t0.addingTimeInterval(offset), grillTemp: 250, grillSetTemp: 250,
                   probes: [:], auger: auger, fan: true, igniter: false)
    }
    let now = t0.addingTimeInterval(600)

    h.isNil(PelletEstimate.hoursLeft(samples: [], state: .default, moduleIsOn: false, now: now),
            "a grill that is off has no burn rate")
    h.isNil(PelletEstimate.hoursLeft(samples: [sample(0, auger: true)], state: .default,
                                     moduleIsOn: true, now: now),
            "too little history to estimate")

    // 50% duty on a full hopper: 8 lb/hr × 0.5 = 4 lb/hr, 20 lb ÷ 4 = 5h.
    let half = (0..<8).map { sample(Double($0) * 60, auger: $0 % 2 == 0) }
    if let hours = PelletEstimate.hoursLeft(samples: half, state: .default, moduleIsOn: true, now: now) {
        h.check(abs(hours - 5) < 0.01, "50% duty on a full hopper is ~5h, got \(hours)")
    } else {
        h.check(false, "expected an estimate at 50% duty")
    }

    // An idle auger gives no meaningful rate rather than an infinite one.
    let idle = (0..<8).map { sample(Double($0) * 60, auger: false) }
    h.isNil(PelletEstimate.hoursLeft(samples: idle, state: .default, moduleIsOn: true, now: now),
            "a never-running auger yields no estimate, not infinity")

    // Old samples must not be counted.
    let stale = (0..<8).map { sample(Double($0) * 60 - 7200, auger: true) }
    h.isNil(PelletEstimate.hoursLeft(samples: stale, state: .default, moduleIsOn: true, now: now),
            "samples older than 15 minutes are ignored")
}

h.equal(PelletEstimate.durationLabel(5), "5h", "5h formats cleanly")
h.equal(PelletEstimate.durationLabel(3.1667), "3h 10m", "fractional hours format as h+m")
h.equal(PelletEstimate.durationLabel(0.75), "45m", "under an hour formats as minutes")

// MARK: - Maintenance

// Ported case for case from scripts/test-maintenance.mjs.
h.section("Maintenance (ported from scripts/test-maintenance.mjs)")

do {
    let fresh = MaintenanceState.fresh
    h.equal(Maintenance.isDue(fresh), false, "fresh not due")
    h.equal(Maintenance.reasons(fresh).count, 0, "fresh reasons empty")

    var byCooks = MaintenanceState.fresh
    byCooks.cooksSinceClean = 5
    h.equal(Maintenance.isDue(byCooks), true, "due by cooks")
    h.check(Maintenance.reasons(byCooks).contains { $0.contains("cook") }, "reason names cooks")

    var byHours = MaintenanceState.fresh
    byHours.runSecondsSinceClean = 30 * 3600
    h.equal(Maintenance.isDue(byHours), true, "due by hours")
    h.check(Maintenance.reasons(byHours).contains { $0.contains("h of use") }, "reason names hours")

    var byFlare = MaintenanceState.fresh
    byFlare.flareupsSinceClean = 3
    h.equal(Maintenance.isDue(byFlare), true, "due by flare-ups")
    h.check(Maintenance.reasons(byFlare).contains { $0.contains("flare-up") }, "reason names flare-ups")

    // Just under every threshold is not due.
    var under = MaintenanceState.fresh
    under.cooksSinceClean = 4
    under.runSecondsSinceClean = 29 * 3600
    under.flareupsSinceClean = 2
    h.equal(Maintenance.isDue(under), false, "under thresholds not due")

    // All three at once reads as three reasons, not one.
    var all = MaintenanceState.fresh
    all.cooksSinceClean = 5; all.runSecondsSinceClean = 30 * 3600; all.flareupsSinceClean = 3
    h.equal(Maintenance.reasons(all).count, 3, "every reason is listed, not just the first")
}

do {
    // Flare-up detection: 100° over the setpoint, while running.
    h.equal(Maintenance.isFlareup(grillTemp: 400, grillSetTemp: 250, moduleIsOn: true), true,
            "flare: temp >> setpoint & on")
    h.equal(Maintenance.isFlareup(grillTemp: 300, grillSetTemp: 250, moduleIsOn: true), false,
            "flare: within margin -> no")
    h.equal(Maintenance.isFlareup(grillTemp: 400, grillSetTemp: 250, moduleIsOn: false), false,
            "flare: grill off -> no")
    h.equal(Maintenance.isFlareup(grillTemp: nil, grillSetTemp: 250, moduleIsOn: true), false,
            "flare: missing temp -> no")
    h.equal(Maintenance.isFlareup(grillTemp: 400, grillSetTemp: nil, moduleIsOn: true), false,
            "flare: missing setpoint -> no")
    // Exactly at the margin is not over it.
    h.equal(Maintenance.isFlareup(grillTemp: 350, grillSetTemp: 250, moduleIsOn: true), false,
            "flare: exactly at the margin is not a flare-up")
    h.equal(Maintenance.isFlareup(grillTemp: 351, grillSetTemp: 250, moduleIsOn: true), true,
            "flare: one degree past the margin is")
}

// MARK: - Thermal anomalies

// Ported case for case from scripts/test-thermal.mjs, plus the regime-reset
// cases the desktop covers in the recorder rather than in its unit test.
h.section("Thermal anomalies (ported from scripts/test-thermal.mjs)")

do {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    /// Points spaced `step` apart, ending at `now`.
    func series(_ step: TimeInterval, _ values: [Int]) -> [TempPoint] {
        values.enumerated().map { i, v in
            TempPoint(at: now.addingTimeInterval(-Double(values.count - 1 - i) * step), value: v)
        }
    }

    // Rate.
    if let r = Thermal.rate(over: series(60, [310, 250]), now: now, window: 60) {
        h.check(abs(r + 60) < 1, "rate: steep 60s drop ≈ -60/min, got \(r)")
    } else {
        h.check(false, "rate: expected a value for a full window")
    }
    h.isNil(Thermal.rate(over: series(5, [250, 245]), now: now, window: 60),
            "rate: nil when the span is too short to trust")
    h.isNil(Thermal.rate(over: [], now: now, window: 60), "rate: nil on empty")

    func classify(_ history: [TempPoint], set: Int, grill: Int,
                  atTemp: Bool = true, noPellets: Bool = false,
                  doorActive: Bool = false) -> ThermalVerdict {
        Thermal.classify(history: history, now: now, setTemp: set, grillTemp: grill,
                         atTemp: atTemp, noPellets: noPellets, doorActive: doorActive)
    }

    // Steady at temp: nothing fires.
    var v = classify(series(10, [250, 250, 249, 250, 251, 250]), set: 250, grill: 250)
    h.equal(v.door, false, "steady: no door")
    h.equal(v.pellet, false, "steady: no pellet")

    // A steep drop is a lid opening, and must not also read as pellets.
    v = classify(series(10, [250, 240, 228, 215, 205, 195]), set: 250, grill: 195)
    h.equal(v.door, true, "door: steep drop flags door")
    h.equal(v.pellet, false, "door: not flagged as pellet while door active")

    // A gentle sustained decline is a starving fire, not a lid.
    v = classify(series(30, [250, 243, 236, 228, 220, 212, 205, 198]), set: 250, grill: 198)
    h.equal(v.pellet, true, "pellet: sustained decline flags pellet")
    h.equal(v.door, false, "pellet: gentle slope not flagged as door")

    // Nothing fires during warm-up — the grill has never reached temp.
    v = classify(series(10, [250, 240, 228, 215, 205, 195]), set: 250, grill: 195, atTemp: false)
    h.equal(v.door, false, "warmup: no door when not atTemp")
    h.equal(v.pellet, false, "warmup: no pellet when not atTemp")

    // The controller's own flag suppresses our heuristic — don't double-warn.
    v = classify(series(30, [250, 243, 236, 228, 220, 212, 205, 198]),
                 set: 250, grill: 198, noPellets: true)
    h.equal(v.pellet, false, "noPellets flag: skip our pellet heuristic")

    // An already-latched door also suppresses it.
    v = classify(series(30, [250, 243, 236, 228, 220, 212, 205, 198]),
                 set: 250, grill: 198, doorActive: true)
    h.equal(v.pellet, false, "an open lid is not a starving fire")
}

do {
    // The detector's latching and regime resets.
    let detector = ThermalDetector()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func state(_ grill: Int, set: Int = 250, on: Bool = true, noPellets: Bool = false) -> GrillState {
        var s = GrillState()
        s.moduleIsOn = on; s.grillTemp = grill; s.grillSetTemp = set; s.noPellets = noPellets
        return s
    }

    // Warm up to temp, then drop the lid open.
    var events: [ThermalDetector.Event] = []
    for (i, temp) in [200, 240, 250, 250, 250].enumerated() {
        events += detector.feed(state(temp), now: t0.addingTimeInterval(Double(i) * 10))
    }
    h.equal(events.count, 0, "warming to temp raises nothing")

    var fired: [ThermalDetector.Event] = []
    for (i, temp) in [235, 220, 205, 190].enumerated() {
        fired += detector.feed(state(temp), now: t0.addingTimeInterval(50 + Double(i) * 10))
    }
    h.check(fired.contains { if case .lidOpen = $0 { return true }; return false },
            "a steep drop raises a lid-open event")

    // It must fire once, not on every subsequent reading.
    var repeats: [ThermalDetector.Event] = []
    for (i, temp) in [185, 180, 178].enumerated() {
        repeats += detector.feed(state(temp), now: t0.addingTimeInterval(90 + Double(i) * 10))
    }
    h.check(!repeats.contains { if case .lidOpen = $0 { return true }; return false },
            "the lid-open latch holds — it does not re-fire every reading")

    // Turning the grill off resets everything.
    _ = detector.feed(state(100, on: false), now: t0.addingTimeInterval(200))
    let afterOff = detector.feed(state(100), now: t0.addingTimeInterval(210))
    h.equal(afterOff.count, 0, "a powered-off grill resets the detector rather than firing")
}

do {
    // Lowering the setpoint must not read as a lid opening: the temperature
    // falls steeply and legitimately, which is exactly the door signature.
    let detector = ThermalDetector()
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    func state(_ grill: Int, set: Int) -> GrillState {
        var s = GrillState()
        s.moduleIsOn = true; s.grillTemp = grill; s.grillSetTemp = set
        return s
    }
    for (i, temp) in [400, 400, 400, 400].enumerated() {
        _ = detector.feed(state(temp, set: 400), now: t0.addingTimeInterval(Double(i) * 10))
    }
    var events: [ThermalDetector.Event] = []
    for (i, temp) in [380, 340, 300, 260, 225].enumerated() {
        events += detector.feed(state(temp, set: 225), now: t0.addingTimeInterval(40 + Double(i) * 10))
    }
    h.equal(events.count, 0, "lowering the setpoint does not raise a false lid-open")
}

// MARK: - Meat catalogue

h.section("Shared cooking data")

do {
    // The vendored copy must match the canonical file, or the apps are reading
    // different knowledge. This is the drift guard ADR 0007 depends on.
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let canonical = repoRoot.appendingPathComponent("data/cooking.json")
    let vendored = repoRoot.appendingPathComponent(
        "ios/PitBossKit/Sources/PitBossKit/Resources/cooking.json")

    if let a = try? Data(contentsOf: canonical), let b = try? Data(contentsOf: vendored) {
        h.check(a == b, "data/cooking.json and the vendored copy are identical — run `npm run cooking:sync`")
    } else {
        h.check(false, "both copies of cooking.json should exist at \(canonical.path)")
    }

    // Every method a cut references must exist, or a cut silently loses it.
    let names = Set(MeatCatalog.methods.map(\.name))
    for cut in MeatCatalog.cuts {
        for method in cut.methods {
            h.check(names.contains(method.name),
                    "\(cut.name) references a method that exists")
        }
    }
    // The named accessors must all resolve, since they trap if they don't.
    for method in [CookMethod.threeTwoOne, .twoTwoOne, .zeroTo400,
                   .texasCrutch, .reverseSear, .spatchcock, .hotAndFast] {
        h.check(!method.steps.isEmpty, "\(method.name) resolves from the data file")
    }
}

h.section("Meat catalogue")

do {
    let cuts = MeatCatalog.cuts
    h.check(cuts.count > 30, "the catalogue is worth having, got \(cuts.count) cuts")
    h.check(Set(cuts.map(\.id)).count == cuts.count, "cut ids are unique")

    for cut in cuts {
        h.check(!cut.targets.isEmpty, "\(cut.name) has at least one target")
        h.check(cut.suggested != nil, "\(cut.name) has a suggested target")
        // Nothing plausible falls outside this band; a typo would.
        for target in cut.targets {
            h.check((90...215).contains(target.temperature),
                    "\(cut.name) · \(target.label) = \(target.temperature)° is plausible")
        }
    }

    // Food safety: every poultry cut must offer the 165° floor, and every
    // ground cut its own floor. This is the assertion with actual stakes.
    for cut in MeatCatalog.cuts(in: .poultry) {
        h.check(cut.targets.contains { $0.temperature >= 165 && $0.kind == .safeMinimum },
                "\(cut.name) offers the 165° poultry safe minimum")
    }
    for cut in MeatCatalog.cuts(in: .ground) {
        h.check(cut.targets.contains { $0.kind == .safeMinimum && $0.temperature >= 160 },
                "\(cut.name) offers a ground-meat safe minimum of at least 160°")
    }

    // A target marked as a safe minimum must never be below its category floor.
    for cut in cuts {
        for target in cut.targets where target.kind == .safeMinimum {
            // Against the cut's own floor: a fully-cooked ham being reheated
            // legitimately sits below the raw-pork figure.
            h.check(!MeatCatalog.isBelowSafeMinimum(target, for: cut),
                    "\(cut.name) · \(target.label) is not below its own floor")
        }
    }

    // Texture temps are, by definition, well past any safety threshold.
    for cut in cuts {
        for target in cut.targets where target.kind == .texture {
            h.check(target.temperature >= 90, "\(cut.name) texture target is set")
            if let floor = MeatCatalog.safeMinimum(for: cut.category), target.temperature < 180 {
                h.check(target.temperature >= floor,
                        "\(cut.name) texture target \(target.temperature)° is at or above the \(floor)° floor")
            }
        }
    }

    // The floors themselves.
    h.equal(MeatCatalog.safeMinimum(for: .poultry), 165, "poultry floor is 165°")
    h.equal(MeatCatalog.safeMinimum(for: .ground), 160, "ground floor is 160°")
    h.equal(MeatCatalog.safeMinimum(for: .beef), 145, "whole-muscle floor is 145°")
    h.isNil(MeatCatalog.safeMinimum(for: .other), "no single floor for 'Other'")

    // Below-floor detection, which is what drives the UI warning. Rare steak is
    // a legitimate choice and must be flagged, not hidden or forbidden.
    h.check(MeatCatalog.isBelowSafeMinimum(MeatTarget("Rare", 125, .doneness), in: .beef),
            "rare beef is flagged as below the USDA floor")
    h.check(!MeatCatalog.isBelowSafeMinimum(MeatTarget("Medium", 145, .doneness), in: .beef),
            "145° beef is not below the floor")
    h.check(MeatCatalog.isBelowSafeMinimum(MeatTarget("Medium rare", 135, .doneness), in: .poultry),
            "135° would be flagged for poultry")

    // The per-cut override, which is what the category floor alone got wrong.
    if let ham = cuts.first(where: { $0.name.contains("fully cooked") }) {
        h.equal(ham.safeFloor, 140, "a fully-cooked ham's floor is 140°, not raw pork's 145°")
        h.check(!MeatCatalog.isBelowSafeMinimum(MeatTarget("Reheated", 140, .safeMinimum), for: ham),
                "140° is not below a fully-cooked ham's own floor")
    }
    if let chops = cuts.first(where: { $0.name == "Pork chops" }) {
        h.equal(chops.safeFloor, 145, "raw pork still uses the 145° floor")
    }

    // Barbecue cuts should suggest their texture temperature, not a floor —
    // a brisket pulled at 145° is safe and inedible.
    let briskets = cuts.filter { $0.name.hasPrefix("Brisket") }
    h.equal(briskets.count, 3, "brisket is split into packer, flat and point")
    for cut in briskets {
        h.equal(cut.suggested?.kind, .texture, "\(cut.name) suggests a texture temp")
        h.check(cut.note != nil, "\(cut.name) explains how its portion differs")
    }

    // The portions must differ in the direction that matters: the lean flat is
    // pulled earlier than the fatty point, which is the whole reason to split
    // them. Getting this backwards would actively make briskets worse.
    let flat = briskets.first { $0.name.contains("flat") }
    let point = briskets.first { $0.name.contains("point") }
    let packer = briskets.first { $0.name.contains("packer") }
    if let flat, let point, let packer {
        h.equal(flat.suggested?.temperature, 200, "the lean flat is pulled at 200°")
        h.equal(point.suggested?.temperature, 205, "the fatty point goes to 205°")
        h.check(flat.suggested!.temperature < point.suggested!.temperature,
                "the flat comes off before the point")
        h.check((flat.suggested!.temperature...point.suggested!.temperature)
                    .contains(packer.suggested!.temperature),
                "a whole packer sits between its two muscles")
    }
    // Chicken breast should suggest the safety floor.
    if let breast = cuts.first(where: { $0.name == "Chicken breast" }) {
        h.equal(breast.suggested?.temperature, 165, "chicken breast suggests 165°")
    }

    // Search.
    h.check(!MeatCatalog.search("brisket").isEmpty, "search finds brisket")
    h.check(!MeatCatalog.search("POULTRY").isEmpty, "search is case-insensitive and matches category")
    h.equal(MeatCatalog.search("").count, cuts.count, "an empty search returns everything")
    h.check(MeatCatalog.search("zzzz").isEmpty, "a nonsense search returns nothing")

    // MARK: Cook presets — pairing a cut with a grill temperature.
    h.check(MeatCatalog.presetable.count > 15, "enough cuts carry a grill temperature")
    for cut in MeatCatalog.presetable {
        let grill = cut.grillTemp!
        h.check((180...500).contains(grill),
                "\(cut.name) grill temp \(grill)° is a plausible setpoint")
        // Collagen cuts are low and slow; poultry needs heat for the skin.
        if cut.targets.contains(where: { $0.kind == .texture && $0.temperature >= 195 }) {
            h.check(grill <= 275, "\(cut.name) is a low-and-slow cut, got \(grill)°")
        }
    }
    if let wings = cuts.first(where: { $0.name == "Chicken wings" }) {
        h.check((wings.grillTemp ?? 0) >= 375, "wings need real heat to crisp the skin")
    }

    // Snapping a recommendation onto the grill's own ladder.
    let pblLadder = [180, 200, 225, 250, 300, 350, 400, 450, 475, 500]
    h.equal(MeatCatalog.nearestSetpoint(to: 250, in: pblLadder), 250, "an exact match is kept")
    h.equal(MeatCatalog.nearestSetpoint(to: 325, in: pblLadder), 300,
            "325° (turkey) snaps to 300° on a ladder that lacks it")
    h.equal(MeatCatalog.nearestSetpoint(to: 275, in: pblLadder), 250,
            "a tie rounds down — overshooting costs the food, undershooting costs time")
    h.equal(MeatCatalog.nearestSetpoint(to: 1000, in: pblLadder), 500, "clamps to the top")
    h.equal(MeatCatalog.nearestSetpoint(to: 50, in: pblLadder), 180, "clamps to the bottom")
    h.isNil(MeatCatalog.nearestSetpoint(to: 250, in: []), "no ladder, no answer")

    // Pork and rib portions, same treatment as brisket.
    let butt = cuts.first { $0.name.contains("Pork butt") }
    let picnic = cuts.first { $0.name.contains("picnic") }
    if let butt, let picnic {
        h.check(butt.suggested!.temperature <= picnic.suggested!.temperature,
                "the leaner picnic wants at least as much heat as the butt")
        h.check(butt.note != nil && picnic.note != nil, "both shoulder portions explain themselves")
    }
    let ribs = cuts.filter { $0.name.localizedCaseInsensitiveContains("rib") && $0.category == .pork }
    h.equal(ribs.count, 3, "spare, St. Louis and baby back ribs are separate")
    if let baby = ribs.first(where: { $0.name.contains("Baby") }),
       let spare = ribs.first(where: { $0.name == "Spare ribs" }) {
        h.check(baby.suggested!.temperature <= spare.suggested!.temperature,
                "leaner baby backs finish at or before spares")
    }

    // MARK: Methods
    h.check(MeatCatalog.methods.count >= 6, "the catalogue carries several methods")
    for method in MeatCatalog.methods {
        h.check(!method.steps.isEmpty, "\(method.name) has steps")
        h.check(!method.summary.isEmpty, "\(method.name) says what it is for")
        for step in method.steps {
            h.check(!step.detail.isEmpty, "\(method.name) · \(step.title) explains itself")
            if let temp = step.grillTemp {
                h.check((180...500).contains(temp),
                        "\(method.name) · \(step.title) at \(temp)° is a real setpoint")
            }
        }
    }

    // 3-2-1 must actually be 3, 2 and 1 hours — the name is the contract.
    h.equal(CookMethod.threeTwoOne.steps.compactMap(\.minutes), [180, 120, 60],
            "3-2-1 is 3h, 2h, 1h")
    h.equal(CookMethod.threeTwoOne.totalMinutes, 360, "…totalling 6 hours")
    h.equal(CookMethod.threeTwoOne.durationLabel, "~6h", "and reads as ~6h")
    h.equal(CookMethod.twoTwoOne.steps.compactMap(\.minutes), [120, 120, 60],
            "2-2-1 is 2h, 2h, 1h for the leaner baby backs")
    h.check(CookMethod.twoTwoOne.totalMinutes! < CookMethod.threeTwoOne.totalMinutes!,
            "baby backs take less time than spares")

    // 0-400 starts cold — that is the entire method, so assert it.
    h.equal(CookMethod.zeroTo400.steps.first?.minutes, 0, "0 to 400 starts from cold")
    h.equal(CookMethod.zeroTo400.grillTemp, 400, "…and runs to 400°")
    h.check(CookMethod.zeroTo400.note?.contains("175") == true,
            "0 to 400 says to pull above the safety floor for crisp skin")

    // Reverse sear must go low *then* hot, or it is just searing.
    let sear = CookMethod.reverseSear.steps.compactMap(\.grillTemp)
    h.check(sear.first! < sear.last!, "reverse sear goes low first, hot last")

    // Chicken: the undercooking case. Dark meat should suggest well above the
    // floor, and every poultry cut must still offer the 165° floor itself.
    if let thighs = cuts.first(where: { $0.name == "Chicken thighs" }) {
        h.check(thighs.suggested!.temperature >= 175, "thighs suggest 175°+, not the bare floor")
    }
    if let wings = cuts.first(where: { $0.name == "Chicken wings" }) {
        h.check(wings.suggested!.temperature >= 180, "wings suggest 180°+ for crisp skin")
        h.check(wings.methods.contains { $0.name == "0 to 400" }, "wings offer the 0-400 method")
    }
    if let breast = cuts.first(where: { $0.name == "Chicken breast" }) {
        h.check(breast.note?.contains("floor") == true,
                "chicken breast explains that 165° is a floor, not a target")
        h.check(breast.targets.contains { $0.temperature > 165 },
                "chicken breast offers a margin above the floor")
    }

    // Methods must be attached where they belong, and nowhere silly.
    let ribCuts = cuts.filter { $0.name.localizedCaseInsensitiveContains("rib") && $0.category == .pork }
    h.check(ribCuts.allSatisfy { !$0.methods.isEmpty }, "every rib cut carries a method")
    if let baby = ribCuts.first(where: { $0.name.contains("Baby") }) {
        h.check(baby.methods.contains { $0.name == "2-2-1" }, "baby backs get 2-2-1, not 3-2-1")
    }
    if let spare = ribCuts.first(where: { $0.name == "Spare ribs" }) {
        h.check(spare.methods.contains { $0.name == "3-2-1" }, "spares get 3-2-1")
    }

    // Every category has something in it, or it shouldn't be on screen.
    for category in MeatCategory.allCases {
        h.check(!MeatCatalog.cuts(in: category).isEmpty, "\(category.label) is not an empty section")
    }
}

// MARK: - Cook continuity

// A cook is the food, not the fire: a pellet outage, a relight or the app
// dying interrupts the *record*, not the brisket. These pin that behaviour.
h.section("Cook continuity across interruptions")

do {
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pitboss-resume-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let scratch = UserDefaults(suiteName: "pitboss-resume-\(UUID().uuidString)")!
    let store = CookStore(directory: tmp, defaults: scratch)
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    func sample(_ offset: Double, _ temp: Int) -> CookSample {
        CookSample(at: t0.addingTimeInterval(offset), grillTemp: temp, grillSetTemp: 250,
                   probes: [1: 140], auger: false, fan: true, igniter: false)
    }

    // A cook that runs, is interrupted, and is never closed.
    let id = store.startCook(at: t0, device: "PBL-TEST")
    store.append(sample(0, 240))
    store.append(sample(5, 245))
    store.append(event: CookEvent(at: t0.addingTimeInterval(10), kind: .outOfPellets))
    store.append(event: CookEvent(at: t0.addingTimeInterval(20), kind: .grillOff))

    // Nothing closed it, so it is resumable.
    let resumable = store.resumableCook(now: t0.addingTimeInterval(600))
    h.equal(resumable?.id, id, "an unclosed cook is resumable")
    h.equal(resumable?.events.count, 2, "its interruptions are in the record")
    h.check(resumable?.events.contains { $0.kind == .outOfPellets } == true,
            "the pellet outage is recorded, not lost")
    h.check(resumable?.events.first?.kind.interruptedTheCook == true,
            "an outage is marked as interrupting the cook itself")

    // Simulate the app dying and coming back.
    let recovered = (try? store.resume(id)) ?? []
    h.equal(recovered.count, 2, "resuming returns the samples already recorded")
    h.equal(store.activeCookID, id, "the same cook is active again, not a new one")
    h.equal(store.activeStartedAt, t0, "the start time survives, so the clock is honest")

    // Appending after the resume extends the same file.
    store.append(event: CookEvent(at: t0.addingTimeInterval(700), kind: .appResumed))
    store.append(sample(705, 200))
    h.equal(store.listCooks().count, 1, "a resumed cook does not create a second file")
    h.equal((try? store.readCook(id))?.count, 3, "the curve continues in one file")

    let meta = store.listCooks().first
    h.equal(meta?.events.count, 3, "every interruption is retained across the resume")
    h.check(meta?.events.contains { $0.kind == .appResumed } == true,
            "the app restart itself is annotated")
    // Events must stay in order or the chart markers land wrong.
    if let events = meta?.events {
        h.check(zip(events, events.dropFirst()).allSatisfy { $0.at <= $1.at },
                "events are ordered by time")
    }

    // A stale cook must not be adopted as today's.
    h.isNil(store.resumableCook(within: 3600, now: t0.addingTimeInterval(48 * 3600)),
            "a day-old unfinished cook is not resumed")

    // Once closed, it is no longer resumable.
    store.endCook(at: t0.addingTimeInterval(800))
    h.isNil(store.resumableCook(now: t0.addingTimeInterval(900)),
            "a closed cook is never resumed")

    // The grace window is long enough for a refill, short enough for a new day.
    h.check(CookStore.interruptionGrace >= 3600, "grace survives a pellet refill and relight")
    h.check(CookStore.interruptionGrace <= 6 * 3600, "grace doesn't swallow the next day's cook")

    // Leave this file for the interop check — it now contains event lines, and
    // the desktop reader must still cope with them.
    if let data = try? Data(contentsOf: tmp.appendingPathComponent("\(id).jsonl")) {
        try? data.write(to: URL(fileURLWithPath: "/tmp/pitboss-interop-events.jsonl"))
    }
}

do {
    // Seeding the live buffer from a resumed cook.
    let history = CookHistory()
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let existing = (0..<4).map {
        CookSample(at: t0.addingTimeInterval(Double($0) * 5), grillTemp: 240 + $0,
                   grillSetTemp: 250, probes: [:], auger: false, fan: true, igniter: false)
    }
    history.resume(with: existing)
    h.equal(history.samples.count, 4, "the resumed curve is loaded")

    // The next reading while the grill is on must not look like a fresh
    // power-on and wipe what was just restored.
    var running = GrillState()
    running.moduleIsOn = true
    running.grillTemp = 245
    running.grillSetTemp = 250
    _ = history.record(running, now: t0.addingTimeInterval(20))
    h.check(history.samples.count >= 5, "recording continues the resumed curve rather than clearing it")
}

// MARK: - Method timeline & cook estimates

h.section("Method stages")

do {
    let t0 = Date(timeIntervalSince1970: 1_750_000_000)
    let ribs = CookMethod.threeTwoOne

    h.check(MethodTimeline.isTimed(ribs), "3-2-1 is a timed method")
    h.equal(MethodTimeline.stageStarts(ribs), [0, 10800, 18000], "stages begin at 0h, 3h, 5h")
    // An untimed method must not invent a clock: a Texas crutch stage ends when
    // the meat stalls, not after N minutes.
    h.check(!MethodTimeline.isTimed(CookMethod.texasCrutch),
            "Texas crutch is not timed — its stages are temperature-driven")
    h.isNil(MethodTimeline.stageStarts(CookMethod.texasCrutch), "…so it has no stage clock")

    func progress(_ hours: Double) -> MethodProgress? {
        MethodTimeline.progress(ribs, startedAt: t0, now: t0.addingTimeInterval(hours * 3600))
    }
    h.equal(progress(0)?.stepIndex, 0, "at the start it's on the smoke stage")
    h.equal(progress(2.9)?.stepIndex, 0, "still smoking just before 3h")
    h.equal(progress(3.1)?.stepIndex, 1, "wrapping just after 3h")
    h.equal(progress(5.1)?.stepIndex, 2, "saucing just after 5h")
    h.equal(progress(6.1)?.isFinished, true, "finished after 6h")
    h.equal(progress(0)?.remaining, 3 * 3600, "3h until the wrap")
    h.check(progress(2.5)?.remainingLabel?.contains("30m") == true,
            "half an hour before the wrap it says so, got \(progress(2.5)?.remainingLabel ?? "nil")")

    // Scheduling: one per later stage plus the finish.
    let stages = MethodTimeline.upcomingStages(ribs, startedAt: t0, now: t0)
    h.equal(stages.count, 3, "3-2-1 schedules wrap, sauce and finish")
    h.equal(stages.first?.offset, 3 * 3600, "the wrap reminder is at 3h")
    h.check(stages.first?.title.contains("Wrap") == true, "…and says to wrap")

    // Resuming mid-method must not fire a burst of stale reminders.
    let late = MethodTimeline.upcomingStages(ribs, startedAt: t0, now: t0.addingTimeInterval(4 * 3600))
    h.equal(late.count, 2, "resuming at 4h only schedules what is still ahead")
    h.check(late.allSatisfy { $0.offset > 0 }, "no reminder is scheduled in the past")
    h.equal(MethodTimeline.upcomingStages(ribs, startedAt: t0, now: t0.addingTimeInterval(9 * 3600)).count,
            0, "a finished method schedules nothing")
}

h.section("Cook time estimates")

// Driven by data/estimate-vectors.json — the same file the desktop runs in
// scripts/test-estimate.mjs. Two implementations of one behaviour held to one
// contract: change the estimator in one app and not the other and this fails
// rather than the two quietly disagreeing. See ADR 0007.
do {
    struct Spec: Decodable {
        struct SampleSpec: Decodable { let epochSeconds: Double; let strideMinutes: Int }
        struct Climb: Decodable { let from: Int; let perHour: Double; let minutes: Int }
        struct Event: Decodable { let atMinutes: Double; let kind: String }
        struct Delta: Decodable { let `case`: String; let delta: Double; let tolerance: Double }
        struct Rate: Decodable { let approx: Double; let tolerance: Double }
        struct Expect: Decodable {
            let kind: String
            let phase: String?
            let ratePerHour: Rate?
            let allowances: [String]?
            let minHours: Double?
            let labelPrefix: String?
            let finishTimeAhead: Bool?
            let sinceSeconds: Double?
            let sinceMinutesAtLeast: Double?
            let noLabel: Bool?
            let explanationContains: String?
            let secondsDeltaVs: Delta?
        }
        struct Case: Decodable {
            let name: String
            let climb: Climb?
            let probe: Int
            let target: Int?
            let nowMinutes: Double
            let events: [Event]?
            let expect: Expect
        }
        let sampleSpec: SampleSpec
        let cases: [Case]
    }

    guard let url = Bundle.module.url(forResource: "estimate-vectors", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let spec = try? JSONDecoder().decode(Spec.self, from: data) else {
        h.check(false, "estimate-vectors.json loads")
        exit(h.finish())
    }

    let epoch = Date(timeIntervalSince1970: spec.sampleSpec.epochSeconds)
    let stride = spec.sampleSpec.strideMinutes

    func samples(_ climb: Spec.Climb?, probe: Int) -> [CookSample] {
        guard let climb else { return [] }
        return Swift.stride(from: 0, through: climb.minutes, by: stride).map { m in
            // The vector file pins "half away from zero", which is what
            // .rounded() already does — stated there because JavaScript's
            // Math.round disagrees on negative halves.
            let value = climb.from + Int((climb.perHour * Double(m) / 60).rounded())
            return CookSample(at: epoch.addingTimeInterval(Double(m) * 60),
                              grillTemp: 250, grillSetTemp: 250,
                              probes: [probe: value],
                              auger: false, fan: true, igniter: false)
        }
    }

    func kindName(_ v: CookEstimate.Verdict) -> String {
        switch v {
        case .eta:          return "eta"
        case .alreadyThere: return "alreadyThere"
        case .stalled:      return "stalled"
        case .tooEarly:     return "tooEarly"
        case .noTarget:     return "noTarget"
        }
    }
    func phaseName(_ p: CookEstimate.Phase) -> String {
        switch p {
        case .beforeStall: return "beforeStall"
        case .inStall:     return "inStall"
        case .afterStall:  return "afterStall"
        case .noStall:     return "noStall"
        }
    }
    func allowanceNames(_ a: [CookEstimate.Allowance]) -> [String] {
        a.map { if case .stall = $0 { return "stall" } else { return "pelletOutage" } }.sorted()
    }

    var verdicts: [String: CookEstimate.Verdict] = [:]
    for c in spec.cases {
        // Samples always carry probe 1; a case asking about another probe is
        // testing that it doesn't borrow probe 1's data.
        let now = epoch.addingTimeInterval(c.nowMinutes * 60)
        let events = (c.events ?? []).map {
            CookEvent(at: epoch.addingTimeInterval($0.atMinutes * 60),
                      kind: CookEvent.Kind(rawValue: $0.kind) ?? .appResumed)
        }
        verdicts[c.name] = CookEstimate.estimate(samples: samples(c.climb, probe: 1),
                                                 probe: c.probe, target: c.target,
                                                 events: events, now: now)
    }

    for c in spec.cases {
        let v = verdicts[c.name]!
        let e = c.expect
        let now = epoch.addingTimeInterval(c.nowMinutes * 60)
        let matched = kindName(v) == e.kind
        h.check(matched, "\(c.name) — \(e.kind)\(matched ? "" : " (got \(kindName(v)))")")
        guard matched else { continue }

        if case .eta(let seconds, let rate, let phase, let allowances) = v {
            if let want = e.phase {
                h.check(phaseName(phase) == want, "  phase \(want)")
            }
            if let want = e.ratePerHour {
                h.check(abs(rate - want.approx) < want.tolerance,
                        "  rate ~\(want.approx)°/hr (got \(String(format: "%.2f", rate)))")
            }
            if let want = e.allowances {
                h.check(allowanceNames(allowances) == want.sorted(),
                        "  allowances [\(want.joined(separator: ", "))]")
            }
            if let want = e.minHours {
                h.check(seconds / 3600 > want,
                        "  over \(want)h (got \(String(format: "%.1f", seconds / 3600))h)")
            }
            if let want = e.labelPrefix {
                h.check(CookEstimate.label(v)?.hasPrefix(want) == true, "  label is hedged")
            }
            if e.finishTimeAhead == true {
                h.check(CookEstimate.finishTime(v, now: now)! > now, "  finish time is ahead")
            }
            if let want = e.secondsDeltaVs {
                if case .eta(let base, _, _, _) = verdicts[want.case] ?? .noTarget {
                    let delta = seconds - base
                    h.check(abs(delta - want.delta) < want.tolerance,
                            "  \(Int(want.delta / 60))m vs baseline (got \(Int(delta / 60))m)")
                } else {
                    h.check(false, "  baseline case \"\(want.case)\" is not an eta")
                }
            }
        }

        if case .stalled(let since) = v {
            if let want = e.sinceSeconds {
                h.check(since == want, "  flat for \(Int(want))s")
            }
            if let want = e.sinceMinutesAtLeast {
                h.check(since >= want * 60,
                        "  flat for >= \(Int(want))m (got \(Int(since / 60))m)")
            }
        }

        if e.noLabel == true { h.isNil(CookEstimate.label(v), "  no number to show") }
        if let want = e.explanationContains {
            h.check(CookEstimate.explanation(v)?.contains(want) == true, "  explained: \"\(want)\"")
        }
    }
}

exit(h.finish())
