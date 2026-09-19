import Foundation

/// Thermal-anomaly detection for a running cook — a port of `src/main/thermal.ts`.
///
/// Two patterns, judged only once the grill has reached its setpoint:
///
/// - **Lid/door open** — a steep, sudden drop as heat is dumped. Recovers when
///   the lid closes.
/// - **Out of pellets** — a slow, sustained decline well below the setpoint that
///   doesn't recover: the fire is starving. Caught *before* the controller's own
///   `noPellets` flag, which is the point of having it.
///
/// Telling them apart is the whole job. Both look like "temperature falling";
/// the difference is the slope, and mistaking a lid opening for a dying fire
/// would cry wolf on every spritz.
public struct TempPoint: Equatable, Sendable {
    public let at: Date
    public let value: Int

    public init(at: Date, value: Int) {
        self.at = at
        self.value = value
    }
}

public struct ThermalThresholds: Equatable, Sendable {
    /// Within this many ° of setpoint counts as "up to temp".
    public let atTempBand: Int
    /// Minimum spacing of trend points.
    public let sampleSeconds: TimeInterval
    /// How much history to retain.
    public let windowSeconds: TimeInterval
    /// Short window for the door drop-rate.
    public let doorWindowSeconds: TimeInterval
    /// °/min fall (or steeper) that reads as a lid opening.
    public let doorRate: Double
    /// …and at least this far below setpoint.
    public let doorMinDrop: Int
    /// Clear the door latch once within this of setpoint.
    public let doorRecover: Int
    /// Long window for the sustained decline.
    public let pelletWindowSeconds: TimeInterval
    /// °/min sustained fall (or steeper).
    public let pelletRate: Double
    /// …while at least this far below setpoint.
    public let pelletDev: Int
    /// Clear the pellet latch once within this of setpoint.
    public let pelletRecover: Int

    public static let standard = ThermalThresholds(
        atTempBand: 15, sampleSeconds: 5, windowSeconds: 6 * 60,
        doorWindowSeconds: 60, doorRate: 25, doorMinDrop: 20, doorRecover: 10,
        pelletWindowSeconds: 4 * 60, pelletRate: 4, pelletDev: 40, pelletRecover: 20)
}

public struct ThermalVerdict: Equatable, Sendable {
    public let door: Bool
    public let pellet: Bool
    /// How far below setpoint, in degrees.
    public let deviation: Int
    public let shortRate: Double?
    public let longRate: Double?
}

public enum Thermal {
    /// Average rate of change (°/min) across `window`, earliest retained sample
    /// to latest.
    ///
    /// Returns nil until the window holds at least half its span, so a buffer
    /// that has only just started filling can't produce a violent-looking rate
    /// from two adjacent samples.
    public static func rate(over history: [TempPoint], now: Date,
                            window: TimeInterval) -> Double? {
        let cutoff = now.addingTimeInterval(-window)
        guard let first = history.first(where: { $0.at >= cutoff }),
              let last = history.last else { return nil }
        let minutes = last.at.timeIntervalSince(first.at) / 60
        guard minutes >= (window / 60) * 0.5, minutes > 0 else { return nil }
        return Double(last.value - first.value) / minutes
    }

    /// Pure classification for this instant — no latching, no side effects.
    /// The caller owns the latches.
    public static func classify(history: [TempPoint], now: Date,
                                setTemp: Int, grillTemp: Int,
                                atTemp: Bool, noPellets: Bool, doorActive: Bool,
                                thresholds t: ThermalThresholds = .standard) -> ThermalVerdict {
        let deviation = setTemp - grillTemp
        let shortRate = rate(over: history, now: now, window: t.doorWindowSeconds)
        let longRate = rate(over: history, now: now, window: t.pelletWindowSeconds)

        let door = atTemp && deviation >= t.doorMinDrop
            && (shortRate.map { $0 <= -t.doorRate } ?? false)

        // A sustained, gentler decline — and explicitly not the sharp door
        // signature, so one lid opening doesn't also read as a starving fire.
        let pellet = atTemp && !noPellets && !(door || doorActive)
            && deviation >= t.pelletDev
            && (longRate.map { $0 <= -t.pelletRate } ?? false)

        return ThermalVerdict(door: door, pellet: pellet, deviation: deviation,
                              shortRate: shortRate, longRate: longRate)
    }
}

/// Stateful wrapper: owns the trend buffer, the "reached temp" flag and the
/// latches, so each anomaly notifies once per occurrence rather than every
/// five seconds while it persists.
public final class ThermalDetector {
    public enum Event: Equatable, Sendable {
        case lidOpen(rate: Int, temperature: Int)
        case starvingFire(temperature: Int, setTemp: Int)
    }

    private let thresholds: ThermalThresholds
    private var history: [TempPoint] = []
    private var atTemp = false
    private var doorFired = false
    private var pelletFired = false
    private var lastSetTemp: Int?
    private var lastSampleAt: Date?

    public init(thresholds: ThermalThresholds = .standard) {
        self.thresholds = thresholds
    }

    /// Feeds a fresh state and returns anomalies that should fire now.
    public func feed(_ state: GrillState, now: Date = Date()) -> [Event] {
        let t = thresholds
        guard state.moduleIsOn == true,
              let setTemp = state.grillSetTemp,
              let grillTemp = state.grillTemp else {
            // Off, or data missing: reset the whole detector rather than
            // carrying a stale trend into the next cook.
            reset()
            lastSetTemp = state.grillSetTemp
            return []
        }

        // A setpoint change starts a fresh regime: require re-reaching temp
        // before warning again. This is also what stops the natural drop after
        // *lowering* the setpoint from reading as a lid opening.
        if setTemp != lastSetTemp {
            lastSetTemp = setTemp
            reset(keepSetTemp: true)
        }
        if grillTemp >= setTemp - t.atTempBand { atTemp = true }

        if lastSampleAt == nil || now.timeIntervalSince(lastSampleAt!) >= t.sampleSeconds {
            lastSampleAt = now
            history.append(TempPoint(at: now, value: grillTemp))
            let cutoff = now.addingTimeInterval(-t.windowSeconds)
            history.removeAll { $0.at < cutoff }
        }

        let verdict = Thermal.classify(history: history, now: now,
                                       setTemp: setTemp, grillTemp: grillTemp,
                                       atTemp: atTemp, noPellets: state.noPellets == true,
                                       doorActive: doorFired, thresholds: t)

        var events: [Event] = []

        if verdict.door {
            if !doorFired {
                doorFired = true
                events.append(.lidOpen(rate: Int((verdict.shortRate ?? 0).rounded()),
                                       temperature: grillTemp))
            }
        } else if verdict.deviation < t.doorRecover {
            doorFired = false
        }

        if verdict.pellet {
            if !pelletFired {
                pelletFired = true
                events.append(.starvingFire(temperature: grillTemp, setTemp: setTemp))
            }
        } else if verdict.deviation < t.pelletRecover {
            pelletFired = false
        }

        return events
    }

    private func reset(keepSetTemp: Bool = false) {
        history.removeAll()
        atTemp = false
        doorFired = false
        pelletFired = false
        lastSampleAt = nil
        if !keepSetTemp { lastSetTemp = nil }
    }
}
