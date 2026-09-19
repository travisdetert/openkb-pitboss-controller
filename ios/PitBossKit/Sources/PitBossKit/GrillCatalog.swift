import Foundation

/// Specifications for one grill model.
public struct Grill: Sendable {
    public let name: String
    public let friendlyName: String?
    public let controlBoard: ControlBoard
    public let hasLights: Bool
    public let minTemp: Int?
    public let maxTemp: Int?
    public let meatProbes: Int
    /// The discrete temperatures the dial supports, e.g. 180/200/225/…/500.
    public let tempIncrements: [Int]

    public var displayName: String { friendlyName ?? name }
}

/// The bundled catalogue of Pit Boss models, loaded from `grills.json`.
///
/// This is the same data file pytboss ships (sourced from the Pit Boss API), so
/// the app supports every model the desktop app does rather than only the one
/// it was developed against.
public final class GrillCatalog: @unchecked Sendable {
    /// Models pytboss excludes: their parsing routines are known-bad or their
    /// data format is nonstandard. Kept in sync with `pytboss/grills.py`.
    static let unsupportedModels: Set<String> = [
        "PBX - test 1", "LG0800BL", "LG1000BL", "LG1200BL", "LG1200FL",
        "LG1200FP", "LG300BL", "LG800FL", "LG800FP", "LGV4BL",
        "PBV30DS", "PBV30DX",
    ]

    private var grills: [String: Grill] = [:]

    /// Loads the catalogue bundled with PitBossKit.
    public static func bundled() throws -> GrillCatalog {
        guard let url = Bundle.module.url(forResource: "grills", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try GrillCatalog(data: Data(contentsOf: url))
    }

    public enum CatalogError: Error, LocalizedError {
        case missingResource
        case malformed
        case unknownModel(String)

        public var errorDescription: String? {
            switch self {
            case .missingResource:      return "grills.json is missing from the bundle"
            case .malformed:            return "grills.json is not in the expected shape"
            case .unknownModel(let m):  return "No such grill model: \(m)"
            }
        }
    }

    public init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CatalogError.malformed
        }
        for (_, value) in root {
            guard let dict = value as? [String: Any],
                  let name = dict["name"] as? String,
                  let boardDict = dict["control_board"] as? [String: Any],
                  // A board with no status routine can't be driven at all.
                  let statusJS = boardDict["status_function"] as? String, !statusJS.isEmpty,
                  !Self.unsupportedModels.contains(name)
            else { continue }

            var commands: [String: BoardCommand] = [:]
            for raw in (boardDict["control_board_commands"] as? [[String: Any]]) ?? [] {
                guard let slug = raw["slug"] as? String else { continue }
                commands[slug] = BoardCommand(
                    name: raw["name"] as? String ?? slug,
                    slug: slug,
                    hex: raw["hexadecimal"] as? String,
                    jsBody: raw["function"] as? String
                )
            }

            let board = ControlBoard(
                name: boardDict["name"] as? String ?? "unknown",
                commands: commands,
                statusJS: statusJS,
                temperaturesJS: boardDict["temperature_function"] as? String
            )

            // min/max arrive as strings and are sometimes words ("Smoke",
            // "High") rather than numbers — those stay nil rather than 0.
            let increments = (dict["temp_increment"] as? String ?? "")
                .split(separator: "/")
                .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }

            grills[name] = Grill(
                name: name,
                friendlyName: dict["friendly_name"] as? String,
                controlBoard: board,
                hasLights: (dict["lights"] as? Int ?? 0) > 0,
                minTemp: Int(dict["min_temp"] as? String ?? ""),
                maxTemp: Int(dict["max_temp"] as? String ?? ""),
                meatProbes: dict["meat_probes"] as? Int ?? 0,
                tempIncrements: increments
            )
        }
    }

    public func grill(named name: String) throws -> Grill {
        guard let g = grills[name] else { throw CatalogError.unknownModel(name) }
        return g
    }

    /// All supported models, optionally narrowed to one control board.
    public func allGrills(controlBoard: String? = nil) -> [Grill] {
        grills.values
            .filter { controlBoard == nil || $0.controlBoard.name == controlBoard }
            .sorted { $0.name < $1.name }
    }

    public var count: Int { grills.count }
}

/// Everything the UI needs, derived from the **control board** alone.
///
/// The board is detectable from the BLE advertisement (`PBL-<MAC>`); the exact
/// chassis model is not reported by the firmware at all (ADR 0003). Since every
/// control board has exactly one decoding behaviour — verified across all 19
/// boards in the catalogue — the board is sufficient for correct decoding and
/// control. The model was only ever supplying display capabilities, so those are
/// derived here instead of asked for.
public struct BoardProfile: Sendable {
    public let board: String
    public let controlBoard: ControlBoard
    public let minTemp: Int
    public let maxTemp: Int
    /// The most probes any grill on this board has. The number actually fitted
    /// is discovered at runtime from the frames.
    public let maxProbes: Int
    /// Step for the fine control between presets.
    public var step: Int { 5 }
    /// One-tap setpoints: every increment any model on this board uses, inside
    /// the board's range.
    ///
    /// This was briefly an *intersection* — the setpoints all models agree on —
    /// on the theory that a preset should be valid on any grill on the board.
    /// That was wrong in practice: for PBL it silently dropped 225, 450, 475 and
    /// 500, which are real setpoints on a PB1100PSC3, to protect a grill the
    /// user doesn't own. It was also inconsistent, since the stepper already
    /// sends arbitrary values and the grill's reported setpoint is treated as
    /// authoritative — so offering a value the firmware rounds costs nothing
    /// that stepping to it didn't already cost.
    public let presets: [Int]
    /// The distinct setpoint ladders among this board's in-range models,
    /// fewest steps first. PBL has two: a 10-step ladder and a 19-step one.
    public let ladderOptions: [[Int]]
    /// Whether grills on this board generally have a controllable light.
    public let hasLights: Bool
    /// How many catalogue models share this board — shown for transparency.
    public let modelCount: Int
}

extension GrillCatalog {
    /// Builds the profile for a control board, e.g. "PBL".
    ///
    /// Range is the most common min/max among the board's models rather than
    /// the widest: one outlier vertical smoker should not stretch the dial for
    /// every other grill on the board.
    public func profile(forBoard board: String) -> BoardProfile? {
        let board = board.uppercased()
        let models = allGrills().filter { $0.controlBoard.name.uppercased() == board }
        guard let first = models.first else { return nil }

        func mostCommon(_ values: [Int]) -> Int? {
            Dictionary(grouping: values, by: { $0 })
                .max { a, b in
                    a.value.count != b.value.count ? a.value.count < b.value.count : a.key < b.key
                }?.key
        }

        let minTemp = mostCommon(models.compactMap(\.minTemp)) ?? 180
        let maxTemp = mostCommon(models.compactMap(\.maxTemp)) ?? 500
        // Union of the ladders belonging to models that share this board's
        // range. Restricting by range matters: PBL includes one 130–420
        // vertical smoker whose fine ladder would otherwise add 310/320/…/420
        // to every 180–500 grill's picker. The grill snaps to its own nearest
        // step if it lacks one exactly, and the UI follows what it took.
        let inRange = models.filter { $0.minTemp == minTemp && $0.maxTemp == maxTemp }
        let contributing = inRange.isEmpty ? models : inRange

        // The distinct ladders, fewest steps first.
        //
        // The default is the *shortest*, which is a deliberate asymmetry: a
        // setpoint the controller doesn't have fails silently — you tap it and
        // nothing happens, with no way to tell why — whereas a missing one is
        // visible and one tap away via the chooser. It also matches the
        // evidence: docs/test-plan.md E1 records the PBL firmware's ladder
        // skipping 250→300, which is the 10-step ladder, and the longer ones in
        // the catalogue look like chassis dial markings rather than firmware.
        var seen = Set<[Int]>()
        var options: [[Int]] = []
        for model in contributing {
            let ladder = model.tempIncrements
                .filter { $0 >= minTemp && $0 <= maxTemp }
                .sorted()
            guard !ladder.isEmpty, !seen.contains(ladder) else { continue }
            seen.insert(ladder)
            options.append(ladder)
        }
        options.sort { $0.count < $1.count }
        let presets = options.first ?? []

        return BoardProfile(
            board: board,
            controlBoard: first.controlBoard,
            minTemp: minTemp,
            maxTemp: maxTemp,
            maxProbes: models.map(\.meatProbes).max() ?? 2,
            presets: presets.isEmpty ? [minTemp, maxTemp] : presets,
            ladderOptions: options.isEmpty ? [[minTemp, maxTemp]] : options,
            hasLights: models.filter(\.hasLights).count * 2 > models.count,
            modelCount: models.count
        )
    }

    /// The control board named by a BLE advertisement such as `PBL-F4CFA2B1F294`.
    public static func board(fromAdvertisedName name: String) -> String? {
        let upper = name.uppercased()
        guard let dash = upper.firstIndex(of: "-") else { return nil }
        let prefix = String(upper[upper.startIndex..<dash])
        return prefix.isEmpty ? nil : prefix
    }
}
