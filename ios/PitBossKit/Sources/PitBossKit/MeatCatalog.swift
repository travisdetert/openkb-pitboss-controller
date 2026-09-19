import Foundation

/// Why a target temperature is what it is.
///
/// Keeping these apart is the point of the whole catalogue. "165° for chicken"
/// and "203° for brisket" are not the same kind of number: one is a food-safety
/// floor you must not go under, the other is where collagen has rendered and is
/// purely about texture. Presenting them identically is how someone talks
/// themselves out of the first one.
public enum TargetKind: String, Codable, Sendable {
    /// USDA FSIS minimum internal temperature. A floor, not a preference.
    case safeMinimum
    /// A doneness preference for whole-muscle cuts.
    case doneness
    /// Well above any safety threshold — cooked for texture.
    case texture
}

public enum MeatCategory: String, CaseIterable, Identifiable, Sendable {
    case beef, pork, poultry, lamb, seafood, ground, other
    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .beef:    return "Beef"
        case .pork:    return "Pork"
        case .poultry: return "Poultry"
        case .lamb:    return "Lamb & Veal"
        case .seafood: return "Fish & Seafood"
        case .ground:  return "Ground & Sausage"
        case .other:   return "Other"
        }
    }
}

public struct MeatTarget: Identifiable, Equatable, Sendable {
    public var id: String { "\(label)-\(temperature)" }
    public let label: String
    public let temperature: Int
    public let kind: TargetKind

    public init(_ label: String, _ temperature: Int, _ kind: TargetKind) {
        self.label = label
        self.temperature = temperature
        self.kind = kind
    }
}

public struct MeatCut: Identifiable, Equatable, Sendable {
    public var id: String { "\(category.rawValue)-\(name)" }
    public let name: String
    public let category: MeatCategory
    /// Targets in ascending temperature. The one marked `isDefault` is
    /// pre-selected; otherwise the first is.
    public let targets: [MeatTarget]
    /// A short practical note — what the number means, or what to watch for.
    public let note: String?
    /// Recommended grill temperature for this cut, where there is a
    /// conventional one. Low and slow for collagen cuts, hot for poultry skin.
    public let grillTemp: Int?
    /// Named techniques for this cut, where the procedure matters as much as
    /// the temperature.
    public let methods: [CookMethod]
    /// Overrides the category floor where the product genuinely has a different
    /// one. A fully-cooked ham being *reheated* is safe at 140°, while raw pork
    /// is 145° — the floor is a property of the product, not just the animal.
    public let safeFloorOverride: Int?

    public init(_ name: String, _ category: MeatCategory,
                _ targets: [MeatTarget], note: String? = nil,
                grillTemp: Int? = nil, methods: [CookMethod] = [],
                safeFloorOverride: Int? = nil) {
        self.name = name
        self.category = category
        self.targets = targets
        self.note = note
        self.grillTemp = grillTemp
        self.methods = methods
        self.safeFloorOverride = safeFloorOverride
    }

    /// The floor that applies to this cut.
    public var safeFloor: Int? {
        safeFloorOverride ?? MeatCatalog.safeMinimum(for: category)
    }

    /// The target to pre-select: the texture one for barbecue cuts, else the
    /// safe minimum, else the middle doneness.
    public var suggested: MeatTarget? {
        targets.first { $0.kind == .texture }
            ?? targets.first { $0.kind == .safeMinimum }
            ?? targets[safe: targets.count / 2]
            ?? targets.first
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// Cuts and their target temperatures.
///
/// Safe minimums are USDA FSIS figures. Doneness temperatures for whole-muscle
/// beef and lamb are the conventional culinary ones and **some sit below the
/// USDA minimum** — they are labelled as preferences and the safe minimum is
/// always shown alongside, rather than quietly omitted, so the choice is the
/// cook's and is an informed one.
///
/// Texture temperatures are ordinary barbecue practice: collagen renders in the
/// 195–205° band, which is why a brisket is "done" far above any safety
/// threshold. Those are guides — probe tenderness is the real test.
/// Cuts, targets and methods, loaded from the shared `cooking.json`.
///
/// The data lives in `data/cooking.json` at the repo root and is vendored into
/// this bundle, exactly as `grills.json` is. One file is the source of truth for
/// every temperature that matters, so a corrected safety figure is fixed once
/// rather than once per app — see ADR 0007.
///
/// Safe minimums are USDA FSIS figures. Doneness temperatures for whole-muscle
/// beef and lamb are the conventional culinary ones and **some sit below the
/// USDA minimum** — they are labelled as preferences and the safe minimum is
/// always shown alongside, rather than quietly omitted, so the choice is the
/// cook's and is an informed one.
///
/// Texture temperatures are ordinary barbecue practice: collagen renders in the
/// 195–205° band, which is why a brisket is "done" far above any safety
/// threshold. Those are guides — probe tenderness is the real test.
public enum MeatCatalog {

    private struct Loaded {
        let cuts: [MeatCut]
        let methods: [CookMethod]
        let floors: [String: Int]
    }

    private static let loaded: Loaded = {
        guard let url = Bundle.module.url(forResource: "cooking", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // The catalogue is bundled at build time; a failure here means a
            // broken build, not a runtime condition worth degrading for.
            fatalError("cooking.json is missing or unreadable")
        }

        let methods: [CookMethod] = (root["methods"] as? [[String: Any]] ?? []).map { m in
            CookMethod(
                m["name"] as? String ?? "",
                m["summary"] as? String ?? "",
                steps: (m["steps"] as? [[String: Any]] ?? []).map { step in
                    MethodStep(step["title"] as? String ?? "",
                               step["detail"] as? String ?? "",
                               minutes: step["minutes"] as? Int,
                               grillTemp: step["grillTemp"] as? Int)
                },
                grillTemp: m["grillTemp"] as? Int,
                note: m["note"] as? String)
        }
        let byName = Dictionary(uniqueKeysWithValues: methods.map { ($0.name, $0) })

        let cuts: [MeatCut] = (root["cuts"] as? [[String: Any]] ?? []).compactMap { c in
            guard let name = c["name"] as? String,
                  let rawCategory = c["category"] as? String,
                  let category = MeatCategory(rawValue: rawCategory) else { return nil }
            let targets: [MeatTarget] = (c["targets"] as? [[String: Any]] ?? []).compactMap { t in
                guard let label = t["label"] as? String,
                      let temperature = t["temperature"] as? Int,
                      let kind = TargetKind(rawValue: t["kind"] as? String ?? "") else { return nil }
                return MeatTarget(label, temperature, kind)
            }
            return MeatCut(name, category, targets,
                           note: c["note"] as? String,
                           grillTemp: c["grillTemp"] as? Int,
                           methods: (c["methods"] as? [String] ?? []).compactMap { byName[$0] },
                           safeFloorOverride: c["safeFloorOverride"] as? Int)
        }

        return Loaded(cuts: cuts, methods: methods,
                      floors: root["safeMinimums"] as? [String: Int] ?? [:])
    }()

    public static var cuts: [MeatCut] { loaded.cuts }

    /// Every distinct method in the catalogue.
    public static var methods: [CookMethod] { loaded.methods }

    /// The USDA FSIS minimum for a category, or nil where there isn't a single
    /// one (e.g. "Other").
    ///
    /// Exposed so the UI can warn whenever a chosen target sits below it,
    /// rather than relying on someone having written a note on every cut. A
    /// rule enforced in one place cannot be forgotten on the fortieth entry.
    public static func safeMinimum(for category: MeatCategory) -> Int? {
        loaded.floors[category.rawValue]
    }

    /// Whether this target is below the safety floor for its category.
    public static func isBelowSafeMinimum(_ target: MeatTarget, in category: MeatCategory) -> Bool {
        guard let floor = safeMinimum(for: category) else { return false }
        return target.temperature < floor
    }

    /// Whether this target is below the floor for this specific cut, honouring
    /// any per-cut override.
    public static func isBelowSafeMinimum(_ target: MeatTarget, for cut: MeatCut) -> Bool {
        guard let floor = cut.safeFloor else { return false }
        return target.temperature < floor
    }

    /// Cuts that carry a recommended grill temperature — the ones a cook
    /// preset can set up end to end.
    public static var presetable: [MeatCut] { cuts.filter { $0.grillTemp != nil } }

    /// The nearest setpoint the grill actually offers.
    ///
    /// A cut's recommended temperature is culinary advice (325° for turkey);
    /// the controller only accepts its own ladder, which may not contain it.
    /// Ties round **down** — undershooting costs time, overshooting costs the
    /// food.
    public static func nearestSetpoint(to wanted: Int, in ladder: [Int]) -> Int? {
        guard !ladder.isEmpty else { return nil }
        return ladder.min { a, b in
            let da = abs(a - wanted), db = abs(b - wanted)
            return da == db ? a < b : da < db
        }
    }

    public static func cuts(in category: MeatCategory) -> [MeatCut] {
        cuts.filter { $0.category == category }
    }

    public static func search(_ query: String) -> [MeatCut] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return cuts }
        return cuts.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.category.label.localizedCaseInsensitiveContains(q)
        }
    }
}
