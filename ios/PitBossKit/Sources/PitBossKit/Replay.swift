import Foundation

/// Replays a recorded cook file through the app, with no grill attached.
///
/// The iOS counterpart to the desktop's `PITBOSS_SHOT`. It exists so the UI can
/// be inspected and captured without standing next to a lit grill — and
/// deliberately replays a **real cook file in the real on-disk format** rather
/// than fabricating a populated view. If the format changes, replay breaks,
/// which is the point.
///
/// Enabled with `PITBOSS_REPLAY=<path to a .jsonl cook>`; `PITBOSS_REPLAY_RATE`
/// sets the speed-up (default 60×, so an hour of cook plays in a minute).
public struct ReplaySource {
    public let samples: [CookSample]
    public let rate: Double

    /// Reads the replay configuration from the environment, if present.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment)
        -> ReplaySource? {
        guard let path = env["PITBOSS_REPLAY"], !path.isEmpty else { return nil }
        let rate = Double(env["PITBOSS_REPLAY_RATE"] ?? "") ?? 60
        guard let raw = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) else {
            PitBossLog.write("[replay] could not read \(path)")
            return nil
        }
        let samples = raw.split(separator: "\n").compactMap { Self.sample(from: String($0)) }
        guard !samples.isEmpty else {
            PitBossLog.write("[replay] no samples in \(path)")
            return nil
        }
        PitBossLog.write("[replay] \(samples.count) samples from \(path) at \(rate)×")
        return ReplaySource(samples: samples, rate: max(1, rate))
    }

    /// Parses one JSONL line — the same shape `CookStore` writes.
    static func sample(from line: String) -> CookSample? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? Double else { return nil }
        var probes: [Int: Int] = [:]
        for probe in 1...4 where obj["p\(probe)Temp"] as? Int != nil {
            probes[probe] = obj["p\(probe)Temp"] as? Int
        }
        return CookSample(at: Date(timeIntervalSince1970: t / 1000),
                          grillTemp: obj["grillTemp"] as? Int,
                          grillSetTemp: obj["grillSetTemp"] as? Int,
                          probes: probes,
                          auger: obj["auger"] as? Bool ?? false,
                          fan: obj["fan"] as? Bool ?? false,
                          igniter: obj["igniter"] as? Bool ?? false)
    }

    /// Turns a recorded sample back into the state the UI consumes.
    public func state(at index: Int) -> GrillState {
        let sample = samples[index]
        var state = GrillState()
        state.moduleIsOn = true
        state.grillTemp = sample.grillTemp
        state.grillSetTemp = sample.grillSetTemp
        state.p1Temp = sample.probes[1]
        state.p2Temp = sample.probes[2]
        state.p3Temp = sample.probes[3]
        state.p4Temp = sample.probes[4]
        state.motorState = sample.auger
        state.fanState = sample.fan
        state.hotState = sample.igniter
        state.isFahrenheit = true
        return state
    }
}
