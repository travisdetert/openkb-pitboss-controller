import Foundation

/// Estimated time until a probe reaches its target.
///
/// Honest about when it can't say. A naive extrapolation through the **stall** —
/// the hours-long plateau where evaporative cooling matches the heat going in —
/// produces answers like "41 hours", which is worse than no answer because
/// someone might believe it. When the rise is too slow or going the wrong way,
/// this returns a reason instead of a number.
public enum CookEstimate {

    /// Where a long cook is in its arc.
    ///
    /// The stall is the defining feature of barbecue timing: somewhere around
    /// 150–170° evaporative cooling matches the heat going in and the meat sits
    /// still for one to several hours before climbing again. An estimate that
    /// doesn't know about it is wrong in both directions — wildly optimistic
    /// before the stall, and absurd during it.
    public enum Phase: Equatable, Sendable {
        /// Climbing, with the stall still ahead.
        case beforeStall
        /// Flat in the stall band.
        case inStall
        /// Climbing again, past the plateau. The reliable phase.
        case afterStall
        /// Not a cut that stalls (poultry, steak, anything below ~190°).
        case noStall
    }

    /// Time added to a raw extrapolation for something the rate can't see.
    ///
    /// Declared rather than folded in silently: an estimate that quietly
    /// includes two and a half hours of padding is not the same claim as one
    /// that doesn't, and the cook should be able to tell which they're reading.
    public enum Allowance: Equatable, Sendable {
        case stall(TimeInterval)
        case pelletOutage(count: Int, TimeInterval)

        public var seconds: TimeInterval {
            switch self {
            case .stall(let s):           return s
            case .pelletOutage(_, let s): return s
            }
        }

        public var label: String {
            switch self {
            case .stall:
                return "~1½h for the stall"
            case .pelletOutage(let count, _):
                return count == 1 ? "~1h for the pellet outage"
                                  : "~\(count)h for \(count) pellet outages"
            }
        }
    }

    public enum Verdict: Equatable, Sendable {
        /// Seconds remaining, with the rate it came from (°/hour), the phase it
        /// was made in, and any time added on top of the raw extrapolation.
        case eta(seconds: TimeInterval, ratePerHour: Double,
                 phase: Phase, allowances: [Allowance])
        case alreadyThere
        /// In the stall. Carries how long it has already been flat.
        case stalled(sinceSeconds: TimeInterval)
        /// Not enough history yet.
        case tooEarly
        case noTarget

        public var isEstimate: Bool { if case .eta = self { return true }; return false }
    }

    /// The band where the stall happens.
    public static let stallBand = 150...175

    /// Only cuts taken well past doneness stall — a 165° chicken never does.
    public static let stallingTargetFloor = 190

    /// Typical stall length, added to an estimate made before one.
    ///
    /// 90 minutes is a middling figure for an unwrapped brisket or butt; they
    /// range from under an hour to over three. It is declared in the result so
    /// the UI can say the allowance is included rather than implying precision
    /// the number doesn't have.
    public static let stallAllowance: TimeInterval = 90 * 60

    /// What one pellet outage costs.
    ///
    /// Roughly an hour: the fire goes out, the meat coasts down, and once the
    /// hopper is refilled the grill has to relight and climb back before the
    /// meat starts moving again. The measured rate can't see this — by the time
    /// the probe is rising again the loss is already behind it — so it's added
    /// explicitly for outages recent enough to still be costing time.
    public static let pelletOutageAllowance: TimeInterval = 60 * 60

    /// How recently an outage still counts against the remaining time. Older
    /// ones are already reflected in the temperature the probe has reached.
    public static let outageRelevanceWindow: TimeInterval = 2 * 3600

    /// How much recent history to derive the rate from.
    ///
    /// 45 minutes, deliberately long: meat climbs a few degrees an hour, so a
    /// short window is mostly sensor noise and would swing the estimate wildly.
    public static let window: TimeInterval = 45 * 60

    /// Below this rate the answer is "stalled", not a very large number.
    public static let minimumRatePerHour = 1.5

    public static func estimate(samples: [CookSample], probe: Int, target: Int?,
                                events: [CookEvent] = [],
                                now: Date = Date()) -> Verdict {
        guard let target else { return .noTarget }

        let points = samples.compactMap { sample -> (Date, Int)? in
            guard let value = sample.probes[probe] else { return nil }
            return (sample.at, value)
        }
        guard let latest = points.last else { return .tooEarly }
        if latest.1 >= target { return .alreadyThere }

        let cutoff = now.addingTimeInterval(-window)
        guard let first = points.first(where: { $0.0 >= cutoff }) else { return .tooEarly }
        let span = latest.0.timeIntervalSince(first.0)
        // Need at least half the window, or the rate is guesswork.
        guard span >= window / 2 else { return .tooEarly }

        let ratePerHour = Double(latest.1 - first.1) / (span / 3600)
        let current = latest.1
        let stalls = target >= stallingTargetFloor

        // Flat, in the band, on a cut that stalls: say so, and say how long it
        // has been flat — "stalled for 40 minutes" is information, a number
        // extrapolated from a zero rate is not.
        if ratePerHour < minimumRatePerHour {
            guard stalls, stallBand.contains(current) else { return .stalled(sinceSeconds: 0) }
            var flatSince = latest.0
            for (at, value) in points.reversed() {
                if abs(value - current) <= 2 { flatSince = at } else { break }
            }
            return .stalled(sinceSeconds: latest.0.timeIntervalSince(flatSince))
        }

        let naive = Double(target - current) / ratePerHour * 3600

        // A recent outage costs time the rate can't account for.
        var allowances: [Allowance] = []
        let recentOutages = events.filter {
            $0.kind == .outOfPellets && now.timeIntervalSince($0.at) <= outageRelevanceWindow
        }.count
        if recentOutages > 0 {
            allowances.append(.pelletOutage(count: recentOutages,
                                            TimeInterval(recentOutages) * pelletOutageAllowance))
        }

        let phase: Phase
        if !stalls {
            phase = .noStall
        } else if current < stallBand.lowerBound {
            // The stall is still ahead, so a straight extrapolation is too
            // optimistic by roughly the length of one.
            phase = .beforeStall
            allowances.append(.stall(stallAllowance))
        } else if current <= stallBand.upperBound {
            // Climbing inside the band — it may be pushing through, but the
            // stall could still bite, so keep part of the allowance.
            phase = .inStall
            allowances.append(.stall(stallAllowance / 2))
        } else {
            phase = .afterStall
        }

        let padding = allowances.reduce(0) { $0 + $1.seconds }
        return .eta(seconds: naive + padding, ratePerHour: ratePerHour,
                    phase: phase, allowances: allowances)
    }

    /// "~2h 40m", or nil when there is no estimate to render.
    public static func label(_ verdict: Verdict) -> String? {
        guard case .eta(let seconds, _, _, _) = verdict else { return nil }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        if h >= 1 { return m > 0 ? "~\(h)h \(m)m" : "~\(h)h" }
        return "~\(max(1, m))m"
    }

    /// The finish time, for "ready around 4:20 PM".
    public static func finishTime(_ verdict: Verdict, now: Date = Date()) -> Date? {
        guard case .eta(let seconds, _, _, _) = verdict else { return nil }
        return now.addingTimeInterval(seconds)
    }

    /// A short reason when there's no number, so the UI never just goes blank.
    public static func explanation(_ verdict: Verdict) -> String? {
        switch verdict {
        case .eta(_, _, _, let allowances):
            guard !allowances.isEmpty else { return nil }
            return "includes " + allowances.map(\.label).joined(separator: " and ")
        case .alreadyThere:
            return "at target"
        case .stalled(let since):
            let minutes = Int(since / 60)
            return minutes >= 10
                ? "stalled \(minutes)m — normal, it can last hours"
                : "stalled — this can last one to three hours"
        case .tooEarly:
            return "estimate in ~25m"
        case .noTarget:
            return nil
        }
    }
}
