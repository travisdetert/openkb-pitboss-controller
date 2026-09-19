import Foundation

/// What the grill did with a setpoint we asked for.
public struct SetpointObservation: Equatable, Sendable, Codable {
    public let requested: Int
    public let reported: Int
    public var accepted: Bool { requested == reported }

    public init(requested: Int, reported: Int) {
        self.requested = requested
        self.reported = reported
    }
}

/// Narrows which model a grill is, from how it answers setpoint requests.
///
/// The firmware reports no model (ADR 0003), but the per-model temperature
/// ladders *are* known — `grills.json` carries `temp_increment` for all 128
/// models. So the missing link is identification, not data. Rather than asking
/// the cook to pick, this eliminates candidates from what the grill does:
///
/// - Asked for 225 and the grill reports 225 → it has 225 → drop every
///   candidate whose ladder lacks it.
/// - Asked for 190 and the grill reports something else → it lacks 190 → drop
///   every candidate whose ladder contains it.
///
/// For PBL that splits 6 models two-vs-three on the first non-universal
/// setpoint, and usually lands on one ladder quickly.
///
/// ⚠️ This rests on one unverified behaviour: that `grillSetTemp` reports what
/// the controller *accepted* rather than echoing the request. Until that is
/// observed on real hardware, inference stays **advisory** — it narrows the
/// displayed ladder but never hides a setpoint the cook previously used, and
/// `GrillController` records observations either way so the question can be
/// answered from the log.
public struct LadderInference: Sendable {

    /// Candidates still consistent with everything observed.
    public static func narrow(candidates: [Grill],
                              observations: [SetpointObservation]) -> [Grill] {
        guard !observations.isEmpty else { return candidates }
        let surviving = candidates.filter { model in
            let ladder = Set(model.tempIncrements)
            // A model with no ladder tells us nothing; never eliminate on it.
            guard !ladder.isEmpty else { return true }
            return observations.allSatisfy { observation in
                observation.accepted ? ladder.contains(observation.requested)
                                     : !ladder.contains(observation.requested)
            }
        }
        // Never narrow to nothing: a contradictory set means an assumption is
        // wrong, and falling back beats showing an empty picker.
        return surviving.isEmpty ? candidates : surviving
    }

    /// The setpoints to offer, given what is still possible.
    ///
    /// Union of the surviving candidates' ladders, plus anything the grill has
    /// already demonstrably accepted — a setpoint it took is real regardless of
    /// what the catalogue says.
    public static func ladder(candidates: [Grill],
                              observations: [SetpointObservation],
                              range: ClosedRange<Int>) -> [Int] {
        let surviving = narrow(candidates: candidates, observations: observations)
        var values = Set(surviving.flatMap(\.tempIncrements))
        values.formUnion(observations.filter(\.accepted).map(\.requested))
        // Anything the grill demonstrably refused is not offered again.
        for refused in observations.filter({ !$0.accepted }).map(\.requested) {
            values.remove(refused)
        }
        return values.filter { $0 >= range.lowerBound && $0 <= range.upperBound }.sorted()
    }

    /// How confident we are, for display. Nil when nothing has been learned.
    public static func summary(candidates: [Grill],
                               observations: [SetpointObservation]) -> String? {
        guard !observations.isEmpty else { return nil }
        let surviving = narrow(candidates: candidates, observations: observations)
        if surviving.count == 1 {
            return "Matched to \(surviving[0].name) from \(observations.count) setpoint\(observations.count == 1 ? "" : "s")."
        }
        return "Narrowed to \(surviving.count) of \(candidates.count) models from \(observations.count) setpoint\(observations.count == 1 ? "" : "s")."
    }
}

/// Persisted setpoint observations, per grill.
public struct LadderMemory: Sendable {
    private static func key(_ grill: String) -> String { "ladder.\(grill)" }

    public static func load(grill: String, from defaults: UserDefaults = .standard) -> [SetpointObservation] {
        guard let data = defaults.data(forKey: key(grill)),
              let value = try? JSONDecoder().decode([SetpointObservation].self, from: data)
        else { return [] }
        return value
    }

    public static func record(_ observation: SetpointObservation,
                              grill: String,
                              to defaults: UserDefaults = .standard) -> [SetpointObservation] {
        var all = load(grill: grill, from: defaults)
        // One entry per requested value; a later answer supersedes an earlier.
        all.removeAll { $0.requested == observation.requested }
        all.append(observation)
        if let data = try? JSONEncoder().encode(all) {
            defaults.set(data, forKey: key(grill))
        }
        return all
    }

    public static func clear(grill: String, from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(grill))
    }
}
