import Foundation

/// Something that interrupted a cook without ending it.
///
/// A cook is the *food*, not the fire. A pellet outage, a dead phone battery or
/// a dropped link all stop the recording for a while; none of them mean the
/// brisket came off. Splitting the record at each one loses the shape of the
/// cook, so instead the interruption is written into the file and drawn on the
/// chart.
public struct CookEvent: Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case grillOff = "grill-off"
        case grillOn = "grill-on"
        case outOfPellets = "out-of-pellets"
        case linkLost = "link-lost"
        case linkRestored = "link-restored"
        case appResumed = "app-resumed"
        case methodStarted = "method-started"

        public var label: String {
            switch self {
            case .grillOff:     return "Grill off"
            case .grillOn:      return "Grill relit"
            case .outOfPellets: return "Out of pellets"
            case .linkLost:     return "Lost connection"
            case .linkRestored: return "Reconnected"
            case .appResumed:   return "App resumed"
            case .methodStarted: return "Method started"
            }
        }

        /// Whether this interrupted the cook itself rather than just the record.
        public var interruptedTheCook: Bool {
            switch self {
            case .grillOff, .outOfPellets: return true
            case .grillOn, .linkLost, .linkRestored, .appResumed, .methodStarted: return false
            }
        }
    }

    public var id: String { "\(kind.rawValue)-\(at.timeIntervalSince1970)" }
    public let at: Date
    public let kind: Kind

    public init(at: Date, kind: Kind) {
        self.at = at
        self.kind = kind
    }
}

/// Metadata for one recorded cook.
public struct CookMeta: Identifiable, Equatable, Sendable {
    public let id: String            // file stem, e.g. "2026-06-23T18-30-00"
    public let startedAt: Date
    public let endedAt: Date?        // nil while still running
    public let sampleCount: Int
    public let device: String?
    public var name: String?
    /// Interruptions recorded during the cook.
    public var events: [CookEvent] = []         // optional user label

    public var duration: TimeInterval? {
        endedAt.map { $0.timeIntervalSince(startedAt) }
    }
}

/// Persists cooks to disk, one file per cook.
///
/// **The on-disk format is deliberately identical to the desktop recorder's**
/// (`src/main/recorder.ts`): `<userData>/cooks/<stem>.jsonl`, a `meta` line, one
/// JSON object per sample, then an `end` line. Same schema means a cook copied
/// off a phone opens in the desktop app and vice versa; diverging would have
/// bought nothing.
///
/// Lines are appended as the cook runs rather than written at the end, so a
/// crash — or iOS killing a backgrounded app — costs at most the last interval
/// instead of the whole cook.
public final class CookStore: @unchecked Sendable {

    public enum StoreError: Error, LocalizedError {
        case invalidID(String)
        case refusedActiveCook(String)

        public var errorDescription: String? {
            switch self {
            case .invalidID(let id):        return "'\(id)' is not a valid cook id."
            case .refusedActiveCook(let id): return "Cook \(id) is still recording."
            }
        }
    }

    private let directory: URL
    private let queue = DispatchQueue(label: "com.openkb.pit-boss.cooks")
    private let defaults: UserDefaults

    /// Currently recording cook, if any.
    public private(set) var activeCookID: String?
    /// When the active cook began — the resumed time when resuming, so the
    /// session clock shows the true elapsed cook, not time since relaunch.
    public private(set) var activeStartedAt: Date?
    private var activeCount = 0
    private var handle: FileHandle?

    public init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cooks", isDirectory: true)
        self.directory = base
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    // MARK: - Identifiers

    /// `2026-06-23T18:30:00.000Z` → `2026-06-23T18-30-00`: filename-safe and
    /// sortable, matching the desktop's `fileStem()`.
    public static func fileStem(for date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    /// A cook id is always a `fileStem()` timestamp.
    ///
    /// This is a path-traversal guard, not a formality: an id becomes a
    /// filename, so anything shaped like `../../x` must be rejected *before* a
    /// path is built. The desktop carries the same check for the same reason
    /// (see SECURITY.md, 2026-07-21).
    public static func isValidID(_ id: String) -> Bool {
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}$"#
        return id.range(of: pattern, options: .regularExpression) != nil
    }

    private func url(for id: String) throws -> URL {
        guard Self.isValidID(id) else { throw StoreError.invalidID(id) }
        return directory.appendingPathComponent("\(id).jsonl")
    }

    // MARK: - Recording

    /// Opens a new cook file. Returns its id.
    @discardableResult
    public func startCook(at date: Date = Date(), device: String?) -> String {
        queue.sync {
            closeActive(endedAt: nil)
            let id = Self.fileStem(for: date)
            activeCookID = id
            activeStartedAt = date
            activeCount = 0

            let file = directory.appendingPathComponent("\(id).jsonl")
            if !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(atPath: file.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: file)
            _ = try? handle?.seekToEnd()

            var meta: [String: Any] = ["type": "meta", "startedAt": millis(date)]
            if let device { meta["device"] = device }
            write(meta)
            PitBossLog.write("[cook] started \(id)")
            return id
        }
    }

    /// Records an interruption without ending the cook.
    ///
    /// Written with an `at` key rather than `t`, deliberately: the desktop's
    /// reader keeps any line with a numeric `t` as a sample, so an event that
    /// used `t` would be misread as a temperature reading. This keeps the file
    /// readable by the desktop app, which simply ignores the line.
    public func append(event: CookEvent) {
        queue.sync {
            guard handle != nil else { return }
            write(["type": "event", "at": millis(event.at), "kind": event.kind.rawValue])
            PitBossLog.write("[cook] event \(event.kind.rawValue)")
        }
    }

    /// Appends one sample to the active cook.
    public func append(_ sample: CookSample) {
        queue.sync {
            guard handle != nil else { return }
            var line: [String: Any] = [
                "t": millis(sample.at),
                "grillTemp": sample.grillTemp as Any? ?? NSNull(),
                "grillSetTemp": sample.grillSetTemp as Any? ?? NSNull(),
                "auger": sample.auger,
                "fan": sample.fan,
                "igniter": sample.igniter,
            ]
            // Written as p1Temp…p4Temp with explicit nulls, exactly as the
            // desktop does, so a reader can't mistake absent for zero.
            for probe in 1...4 {
                line["p\(probe)Temp"] = sample.probes[probe] as Any? ?? NSNull()
            }
            write(line)
            activeCount += 1
        }
    }

    /// Closes the active cook.
    public func endCook(at date: Date = Date()) {
        queue.sync {
            guard let id = activeCookID else { return }
            closeActive(endedAt: date)
            PitBossLog.write("[cook] ended \(id) (\(activeCount) samples)")
        }
    }

    private func closeActive(endedAt: Date?) {
        if handle != nil, let endedAt {
            write(["type": "end", "endedAt": millis(endedAt)])
        }
        try? handle?.close()
        handle = nil
        activeCookID = nil
        activeStartedAt = nil
        activeCount = 0
    }

    private func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              var line = String(data: data, encoding: .utf8)?.data(using: .utf8) else { return }
        line.append(0x0A)  // newline — JSONL
        do { try handle?.write(contentsOf: line) }
        catch { PitBossLog.write("[cook] write failed: \(error.localizedDescription)") }
    }

    private func millis(_ date: Date) -> Int { Int(date.timeIntervalSince1970 * 1000) }

    // MARK: - Resuming

    /// The most recent cook that was never closed, if it's recent enough to
    /// still be the same cook.
    ///
    /// A cook file has no `end` line when the app stopped before the grill did
    /// — a dead battery, a force quit, iOS reclaiming a backgrounded app. On
    /// the next launch that cook is very likely still running on the grill, and
    /// starting a second file for it loses the first half of the curve.
    ///
    /// Bounded by `within` so yesterday's abandoned file isn't adopted as
    /// today's cook.
    public func resumableCook(within: TimeInterval = 24 * 3600,
                              now: Date = Date()) -> CookMeta? {
        listCooks().first { meta in
            meta.endedAt == nil && now.timeIntervalSince(meta.startedAt) < within
        }
    }

    /// How long the grill can be off before the cook is treated as finished
    /// rather than interrupted.
    ///
    /// Two hours: long enough to survive a pellet refill, a relight, or a flat
    /// phone battery; short enough that tomorrow's cook doesn't get appended to
    /// today's.
    public static let interruptionGrace: TimeInterval = 2 * 3600

    /// Reopens an unfinished cook for appending and returns what it already
    /// holds, so the live curve picks up where it left off.
    @discardableResult
    public func resume(_ id: String) throws -> [CookSample] {
        let file = try url(for: id)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let existing = try readCook(id)

        queue.sync {
            closeActive(endedAt: nil)
            activeCookID = id
            activeStartedAt = parseStem(id)
            activeCount = existing.count
            handle = try? FileHandle(forWritingTo: file)
            _ = try? handle?.seekToEnd()
            PitBossLog.write("[cook] resumed \(id) with \(existing.count) existing samples")
        }
        return existing
    }

    // MARK: - Reading

    /// Every recorded cook, newest first.
    public func listCooks() -> [CookMeta] {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return files
                .filter { $0.hasSuffix(".jsonl") }
                .compactMap { meta(forFile: $0) }
                .sorted { $0.startedAt > $1.startedAt }
        }
    }

    public func readCook(_ id: String) throws -> [CookSample] {
        let file = try url(for: id)
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return raw.split(separator: "\n").compactMap { sample(fromLine: String($0)) }
    }

    public func deleteCook(_ id: String) throws {
        let file = try url(for: id)
        // Never delete a cook that is still being written to.
        if id == activeCookID { throw StoreError.refusedActiveCook(id) }
        try FileManager.default.removeItem(at: file)
        defaults.removeObject(forKey: nameKey(id))
        PitBossLog.write("[cook] deleted \(id)")
    }

    /// Names live beside the data, not inside it, so renaming never rewrites a
    /// recorded file.
    public func renameCook(_ id: String, to name: String) throws {
        guard Self.isValidID(id) else { throw StoreError.invalidID(id) }
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        if trimmed.isEmpty { defaults.removeObject(forKey: nameKey(id)) }
        else { defaults.set(trimmed, forKey: nameKey(id)) }
    }

    private func nameKey(_ id: String) -> String { "cookName.\(id)" }

    private func meta(forFile filename: String) -> CookMeta? {
        let id = String(filename.dropLast(".jsonl".count))
        guard Self.isValidID(id) else { return nil }
        let file = directory.appendingPathComponent(filename)
        guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return nil }

        var startedAt: Date?
        var endedAt: Date?
        var device: String?
        var count = 0
        var events: [CookEvent] = []

        for line in raw.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            switch obj["type"] as? String {
            case "meta":
                startedAt = (obj["startedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
                device = obj["device"] as? String
            case "end":
                endedAt = (obj["endedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            case "event":
                if let at = obj["at"] as? Double,
                   let raw = obj["kind"] as? String,
                   let kind = CookEvent.Kind(rawValue: raw) {
                    events.append(CookEvent(at: Date(timeIntervalSince1970: at / 1000), kind: kind))
                }
            default:
                if obj["t"] != nil { count += 1 }
            }
        }

        // A file with no meta line (interrupted write) still has a usable id.
        let started = startedAt ?? parseStem(id) ?? Date(timeIntervalSince1970: 0)
        return CookMeta(id: id, startedAt: started, endedAt: endedAt,
                        sampleCount: count, device: device,
                        name: defaults.string(forKey: nameKey(id)),
                        events: events.sorted { $0.at < $1.at })
    }

    private func parseStem(_ id: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: id)
    }

    private func sample(fromLine line: String) -> CookSample? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? Double
        else { return nil }

        var probes: [Int: Int] = [:]
        for probe in 1...4 {
            if let v = obj["p\(probe)Temp"] as? Int { probes[probe] = v }
        }
        return CookSample(
            at: Date(timeIntervalSince1970: t / 1000),
            grillTemp: obj["grillTemp"] as? Int,
            grillSetTemp: obj["grillSetTemp"] as? Int,
            probes: probes,
            // Optional in the desktop schema so older files still parse.
            auger: obj["auger"] as? Bool ?? false,
            fan: obj["fan"] as? Bool ?? false,
            igniter: obj["igniter"] as? Bool ?? false)
    }
}
