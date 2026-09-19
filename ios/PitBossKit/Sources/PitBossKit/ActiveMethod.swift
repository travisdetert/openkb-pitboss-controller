import Foundation

/// A method being followed right now.
///
/// Methods are only useful if they tell you *when* to do the next thing. 3-2-1
/// is three timers and two actions; reading the steps and then setting phone
/// alarms by hand is the part the app should be doing.
///
/// Persisted, because the stages that matter are hours apart — long enough for
/// the app to be killed, the phone to die, or the cook to walk away.
public struct ActiveMethod: Codable, Equatable, Sendable {
    public let methodName: String
    public let startedAt: Date
    /// The cut it was started for, for the notification wording.
    public let cutName: String?

    public init(methodName: String, startedAt: Date, cutName: String?) {
        self.methodName = methodName
        self.startedAt = startedAt
        self.cutName = cutName
    }

    private static let key = "activeMethod"

    public static func load(from defaults: UserDefaults = .standard) -> ActiveMethod? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ActiveMethod.self, from: data)
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    public static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

/// Where a method has got to.
public struct MethodProgress: Equatable, Sendable {
    public let method: CookMethod
    public let stepIndex: Int
    public let step: MethodStep
    /// Time until the next stage, or nil on an untimed or final stage.
    public let remaining: TimeInterval?
    public let elapsed: TimeInterval
    public let isFinished: Bool

    public var remainingLabel: String? {
        guard let remaining, remaining > 0 else { return nil }
        let total = Int(remaining)
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return "\(h)h \(m)m left" }
        return m > 0 ? "\(m)m left" : "under a minute"
    }
}

public enum MethodTimeline {
    /// Cumulative offsets at which each stage *begins*, in seconds.
    ///
    /// Only meaningful for methods whose every stage declares a duration —
    /// a Texas crutch stage ends when the meat stalls, not on a clock, and
    /// inventing a time for it would be worse than having none.
    public static func stageStarts(_ method: CookMethod) -> [TimeInterval]? {
        guard method.steps.allSatisfy({ $0.minutes != nil }) else { return nil }
        var offsets: [TimeInterval] = []
        var running: TimeInterval = 0
        for step in method.steps {
            offsets.append(running)
            running += TimeInterval(step.minutes ?? 0) * 60
        }
        return offsets
    }

    public static func isTimed(_ method: CookMethod) -> Bool { stageStarts(method) != nil }

    /// Where the method is now.
    public static func progress(_ method: CookMethod, startedAt: Date,
                                now: Date = Date()) -> MethodProgress? {
        guard !method.steps.isEmpty else { return nil }
        let elapsed = max(0, now.timeIntervalSince(startedAt))

        guard let starts = stageStarts(method) else {
            // Untimed: the cook is on the first stage until they say otherwise.
            return MethodProgress(method: method, stepIndex: 0, step: method.steps[0],
                                  remaining: nil, elapsed: elapsed, isFinished: false)
        }

        let total = starts.last! + TimeInterval(method.steps.last?.minutes ?? 0) * 60
        if elapsed >= total {
            return MethodProgress(method: method, stepIndex: method.steps.count - 1,
                                  step: method.steps.last!, remaining: nil,
                                  elapsed: elapsed, isFinished: true)
        }

        // The last stage whose start has passed.
        var index = 0
        for (i, start) in starts.enumerated() where elapsed >= start { index = i }
        let nextStart = index + 1 < starts.count ? starts[index + 1] : total
        return MethodProgress(method: method, stepIndex: index, step: method.steps[index],
                              remaining: nextStart - elapsed, elapsed: elapsed,
                              isFinished: false)
    }

    /// Notifications to schedule: the moment each later stage begins, plus the
    /// end. Offsets already in the past are dropped — scheduling those would
    /// fire a burst of stale alerts the instant a method is resumed.
    public static func upcomingStages(_ method: CookMethod, startedAt: Date,
                                      now: Date = Date()) -> [(offset: TimeInterval, title: String, body: String)] {
        guard let starts = stageStarts(method) else { return [] }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        var out: [(TimeInterval, String, String)] = []

        for (i, start) in starts.enumerated() where i > 0 && start > elapsed {
            out.append((start - elapsed,
                        "\(method.name): \(method.steps[i].title)",
                        method.steps[i].detail))
        }

        let total = starts.last! + TimeInterval(method.steps.last?.minutes ?? 0) * 60
        if total > elapsed {
            out.append((total - elapsed,
                        "\(method.name) finished",
                        method.note ?? "Check it — the clock is a guide, not the test."))
        }
        return out
    }
}
