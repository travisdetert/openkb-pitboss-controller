import Foundation

/// Estimated pellet level, derived from cumulative auger run-time.
///
/// Rough by nature and honest about it: there is no pellet sensor on the grill,
/// so this integrates how long the auger has run since the last refill and
/// converts that to pounds at an assumed feed rate. The defaults match the
/// desktop's (20 lb hopper, 8 lb/hr of auger run-time); the cook recalibrates
/// by tapping **Refilled**, which is what keeps it useful rather than merely
/// plausible.
public struct PelletState: Codable, Equatable, Sendable {
    public var capacityLbs: Double
    public var feedRateLbsPerHr: Double
    /// Cumulative auger-on seconds since the last refill.
    public var augerSeconds: Double
    public var refilledAt: Date?

    public static let `default` = PelletState(
        capacityLbs: 20, feedRateLbsPerHr: 8, augerSeconds: 0, refilledAt: nil)

    public init(capacityLbs: Double = 20, feedRateLbsPerHr: Double = 8,
                augerSeconds: Double = 0, refilledAt: Date? = nil) {
        self.capacityLbs = capacityLbs
        self.feedRateLbsPerHr = feedRateLbsPerHr
        self.augerSeconds = augerSeconds
        self.refilledAt = refilledAt
    }

    // MARK: Persistence

    private static let key = "pelletState"

    public static func load(from defaults: UserDefaults = .standard) -> PelletState {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(PelletState.self, from: data)
        else { return .default }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

public enum PelletEstimate {
    /// The longest gap that counts toward auger run-time.
    ///
    /// Without a cap, a disconnection or a suspended app would be integrated as
    /// hours of continuous feeding and empty the hopper on paper. The desktop
    /// uses the same 10-second clamp.
    public static let maximumTickSeconds: Double = 10

    public enum Level: Sendable { case ok, low, critical }

    public static func remainingPounds(_ state: PelletState) -> Double {
        let used = (state.augerSeconds / 3600) * state.feedRateLbsPerHr
        return max(0, state.capacityLbs - used)
    }

    public static func percent(_ state: PelletState) -> Double {
        guard state.capacityLbs > 0 else { return 0 }
        return max(0, min(100, remainingPounds(state) / state.capacityLbs * 100))
    }

    /// Thresholds match the desktop's bar colouring.
    public static func level(percent: Double) -> Level {
        percent > 40 ? .ok : percent > 15 ? .low : .critical
    }

    /// Adds elapsed auger time, clamped so a gap can't be counted as feeding.
    public static func advance(_ state: PelletState, augerOn: Bool,
                               since last: Date, now: Date) -> PelletState {
        guard augerOn else { return state }
        var next = state
        next.augerSeconds += min(now.timeIntervalSince(last), maximumTickSeconds)
        return next
    }

    /// Hopper refilled: the estimate resets to full.
    public static func refilled(_ state: PelletState, at date: Date = Date()) -> PelletState {
        var next = state
        next.augerSeconds = 0
        next.refilledAt = date
        return next
    }

    /// Hopper emptied to store pellets dry — charge it a full hopper so it reads 0%.
    public static func emptied(_ state: PelletState) -> PelletState {
        var next = state
        guard state.feedRateLbsPerHr > 0 else { return next }
        next.augerSeconds = (state.capacityLbs / state.feedRateLbsPerHr) * 3600
        next.refilledAt = nil
        return next
    }

    /// Rough hours of pellets left, from the recent auger duty cycle.
    ///
    /// Deliberately conservative: the 5-second activity flags over-count brief
    /// pulses, so the duty cycle reads high and the estimate runs short. Better
    /// to go and check the hopper early than to run out mid-brisket.
    ///
    /// Returns nil when the grill is off, when there isn't enough recent
    /// history to be meaningful, or when the burn rate is too low to divide by.
    public static func hoursLeft(samples: [CookSample], state: PelletState,
                                 moduleIsOn: Bool, now: Date = Date()) -> Double? {
        guard moduleIsOn else { return nil }
        let recent = samples.filter { now.timeIntervalSince($0.at) <= 15 * 60 }
        guard recent.count >= 4 else { return nil }

        let duty = Double(recent.filter(\.auger).count) / Double(recent.count)
        let burnLbsPerHour = state.feedRateLbsPerHr * duty
        guard burnLbsPerHour >= 0.05 else { return nil }
        return remainingPounds(state) / burnLbsPerHour
    }

    /// "3h 10m" / "45m", for the readout.
    public static func durationLabel(_ hours: Double) -> String {
        guard hours >= 1 else { return "\(Int((hours * 60).rounded()))m" }
        let whole = Int(hours)
        let minutes = Int(((hours - Double(whole)) * 60).rounded())
        return minutes > 0 ? "\(whole)h \(minutes)m" : "\(whole)h"
    }
}
