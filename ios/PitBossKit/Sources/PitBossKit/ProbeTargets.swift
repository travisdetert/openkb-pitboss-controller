import Foundation

/// Per-probe target temperatures and names.
///
/// Targets are kept **app-side for every probe**, because most boards can only
/// be told about probe 1 — PBL, the board this project was built against, has
/// only `set-probe-1-temperature`. Across the whole catalogue 38 boards accept a
/// probe-1 target and just 27 accept a probe-2 target, and none accept 3 or 4.
/// So the app is the thing that knows what you are cooking to; the grill is told
/// as well, whenever it is capable of caring.
///
/// Defaults match the desktop's (`src/main/store.ts`).
public struct ProbeTargets: Equatable, Sendable {
    public var targets: [Int: Int]
    public var labels: [Int: String]

    public static let `default` = ProbeTargets(targets: [1: 145, 2: 165], labels: [:])

    public init(targets: [Int: Int] = [:], labels: [Int: String] = [:]) {
        self.targets = targets
        self.labels = labels
    }

    public func target(for probe: Int) -> Int? { targets[probe] }

    /// The probe's name, falling back to "Probe N".
    public func label(for probe: Int) -> String {
        let name = labels[probe]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false ? name! : "Probe \(probe)")
    }

    // MARK: Persistence

    private static let targetsKey = "probeTargets"
    private static let labelsKey = "probeLabels"

    public static func load(from defaults: UserDefaults = .standard) -> ProbeTargets {
        var value = ProbeTargets.default
        if let raw = defaults.dictionary(forKey: targetsKey) as? [String: Int] {
            value.targets = Dictionary(uniqueKeysWithValues:
                raw.compactMap { key, v in Int(key).map { ($0, v) } })
        }
        if let raw = defaults.dictionary(forKey: labelsKey) as? [String: String] {
            value.labels = Dictionary(uniqueKeysWithValues:
                raw.compactMap { key, v in Int(key).map { ($0, v) } })
        }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(Dictionary(uniqueKeysWithValues: targets.map { (String($0.key), $0.value) }),
                     forKey: Self.targetsKey)
        defaults.set(Dictionary(uniqueKeysWithValues: labels.map { (String($0.key), $0.value) }),
                     forKey: Self.labelsKey)
    }
}

/// Edge-triggered probe alerting.
///
/// A port of the desktop recorder's probe logic, including the two behaviours
/// that stop it becoming noise:
///
/// - **Hysteresis.** Once "reached target" has fired it will not fire again
///   until the reading falls more than `resetMargin` below the target, so a
///   probe hovering on the boundary doesn't buzz every five seconds.
/// - **Over-target escalation.** Passing the target by `overMargin` is a
///   separate, louder event — the food is overcooking, which is a different
///   problem from it being done.
public struct ProbeAlerting: Sendable {
    public static let resetMargin = 2
    public static let overMargin = 5   // desktop's OVER_TARGET_MARGIN

    public enum Event: Equatable, Sendable {
        case reachedTarget(probe: Int, temperature: Int, target: Int)
        case overTarget(probe: Int, temperature: Int, target: Int)
    }

    /// Latches, kept between evaluations.
    public struct Latches: Equatable, Sendable {
        var reached: Set<Int> = []
        var over: Set<Int> = []
        public init() {}
    }

    /// Evaluates every probe and returns the events that should fire now,
    /// updating the latches in place.
    public static func evaluate(state: GrillState,
                                targets: ProbeTargets,
                                latches: inout Latches) -> [Event] {
        var events: [Event] = []
        for probe in 1...4 {
            guard let current = temperature(state, probe),
                  let target = targets.target(for: probe), target > 0 else { continue }

            if current >= target {
                if !latches.reached.contains(probe) {
                    latches.reached.insert(probe)
                    events.append(.reachedTarget(probe: probe, temperature: current, target: target))
                }
            } else if current < target - resetMargin {
                // Far enough below to arm again for the next cook.
                latches.reached.remove(probe)
            }

            if current >= target + overMargin {
                if !latches.over.contains(probe) {
                    latches.over.insert(probe)
                    events.append(.overTarget(probe: probe, temperature: current, target: target))
                }
            } else if current < target {
                latches.over.remove(probe)
            }
        }
        return events
    }

    static func temperature(_ state: GrillState, _ probe: Int) -> Int? {
        switch probe {
        case 1: return state.p1Temp
        case 2: return state.p2Temp
        case 3: return state.p3Temp
        default: return state.p4Temp
        }
    }
}
