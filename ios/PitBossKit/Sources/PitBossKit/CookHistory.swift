import Foundation

/// One recorded point in a cook.
public struct CookSample: Equatable, Sendable, Identifiable {
    public var id: Date { at }
    public let at: Date
    public let grillTemp: Int?
    public let grillSetTemp: Int?
    public let probes: [Int: Int]      // probe number → temperature
    public let auger: Bool
    public let fan: Bool
    public let igniter: Bool

    public init(at: Date, grillTemp: Int?, grillSetTemp: Int?, probes: [Int: Int],
                auger: Bool, fan: Bool, igniter: Bool) {
        self.at = at
        self.grillTemp = grillTemp
        self.grillSetTemp = grillSetTemp
        self.probes = probes
        self.auger = auger
        self.fan = fan
        self.igniter = igniter
    }
}

/// The rolling record behind the charts and the component timeline.
///
/// Two behaviours are load-bearing and come straight from the desktop recorder:
///
/// 1. **One point per 5 seconds.** Frames arrive faster than that and an
///    unbounded series would grow without limit over a long cook.
/// 2. **Component states are latched between samples.** The auger fires in
///    short pulses; sampling its instantaneous value every 5s would miss most
///    of them and the activity timeline would look idle during a cook that is
///    actually feeding. So activity is OR'd across the interval and the latch
///    is cleared once recorded.
///
/// A fresh power-on starts a new curve, so two cooks in one session don't run
/// together on the chart.
public final class CookHistory: @unchecked Sendable {
    /// At most one recorded point per this interval.
    public static let sampleInterval: TimeInterval = 5

    /// ~12 hours at 5s. A brisket is long; a memory leak is longer.
    public static let maximumSamples = 8_640

    public private(set) var samples: [CookSample] = []

    private var lastSampleAt: Date?
    private var wasOn = false

    // Latches, OR'd between samples.
    private var augerSeen = false
    private var fanSeen = false
    private var igniterSeen = false

    public init() {}

    /// Seeds the buffer from an unfinished cook being resumed, so the chart
    /// shows the whole cook rather than restarting at the relaunch.
    ///
    /// `wasOn` is set true so the resumed state does *not* look like a fresh
    /// power-on and wipe what we just loaded.
    public func resume(with existing: [CookSample]) {
        samples = Array(existing.suffix(Self.maximumSamples))
        lastSampleAt = samples.last?.at
        wasOn = true
        augerSeen = false; fanSeen = false; igniterSeen = false
    }

    /// Feeds a fresh state in. Returns true when a new point was recorded.
    @discardableResult
    public func record(_ state: GrillState, now: Date = Date()) -> Bool {
        // Latch activity on every update, not just on sample boundaries —
        // this is what keeps brief auger pulses visible.
        if state.motorState == true { augerSeen = true }
        if state.fanState == true { fanSeen = true }
        if state.hotState == true { igniterSeen = true }

        // A fresh power-on begins a new cook.
        let isOn = state.moduleIsOn == true
        if isOn && !wasOn {
            samples.removeAll()
            lastSampleAt = nil
        }
        wasOn = isOn

        if let last = lastSampleAt, now.timeIntervalSince(last) < Self.sampleInterval {
            return false
        }
        lastSampleAt = now

        var probes: [Int: Int] = [:]
        if let v = state.p1Temp { probes[1] = v }
        if let v = state.p2Temp { probes[2] = v }
        if let v = state.p3Temp { probes[3] = v }
        if let v = state.p4Temp { probes[4] = v }

        samples.append(CookSample(
            at: now,
            grillTemp: state.grillTemp,
            grillSetTemp: state.grillSetTemp,
            probes: probes,
            auger: augerSeen,
            fan: fanSeen,
            igniter: igniterSeen))

        // Clear the latches for the next interval.
        augerSeen = false
        fanSeen = false
        igniterSeen = false

        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
        return true
    }

    public func clear() {
        samples.removeAll()
        lastSampleAt = nil
        augerSeen = false; fanSeen = false; igniterSeen = false
    }

    /// Probe numbers that appear anywhere in the record.
    public var probesSeen: [Int] {
        Set(samples.flatMap(\.probes.keys)).sorted()
    }

    /// Span covered by the record.
    public var span: (start: Date, end: Date)? {
        guard let first = samples.first, let last = samples.last else { return nil }
        return (first.at, last.at)
    }

    /// Y-axis bounds across grill, setpoint and probes, padded a little.
    public var temperatureRange: ClosedRange<Int>? {
        var values: [Int] = []
        for s in samples {
            if let v = s.grillTemp { values.append(v) }
            if let v = s.grillSetTemp { values.append(v) }
            values.append(contentsOf: s.probes.values)
        }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        // Never render a flat line as a full-height band.
        let pad = max(10, (hi - lo) / 10)
        return (lo - pad)...(hi + pad)
    }

    /// Contiguous runs where a component was active, for the timeline.
    public func runs(for component: KeyPath<CookSample, Bool>) -> [(start: Date, end: Date)] {
        var runs: [(Date, Date)] = []
        var runStart: Date?
        for sample in samples {
            if sample[keyPath: component] {
                if runStart == nil { runStart = sample.at }
            } else if let start = runStart {
                runs.append((start, sample.at))
                runStart = nil
            }
        }
        if let start = runStart, let last = samples.last {
            // Still running: close the run at the latest sample, but keep it
            // visible even when it started on that same sample.
            runs.append((start, max(last.at, start.addingTimeInterval(Self.sampleInterval))))
        }
        return runs
    }
}
