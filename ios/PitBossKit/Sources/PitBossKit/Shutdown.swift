import Foundation

/// Graceful-shutdown decision logic — a direct port of `src/main/shutdown.ts`.
///
/// Why this matters: shutting a hot pellet grill straight off can let the fire
/// smoulder back up the auger toward the hopper — a burnback / hopper fire. On
/// this project's own grill that fire melted a bushing in the auger housing and
/// seized the auger motor, which had to be replaced. It is not a hypothetical.
///
/// The safe procedure is to bring the grill down to ~200°F first, *then* power
/// off so the controller's fan cool-down can fully extinguish the firepot.
///
/// Kept pure and dependency-free, exactly like the TypeScript original, so the
/// same assertions can be run against it (`pitboss-verify`). Thresholds are the
/// desktop's, which were validated on the grill on 2026-07-16 — they are not
/// re-guessed here.
public enum ShutdownPhase: Equatable, Sendable {
    case cooling
    case finishing
}

public struct ShutdownInput: Equatable, Sendable {
    public let moduleIsOn: Bool
    public let grillTemp: Int?
    public let grillSetTemp: Int?
    public let fanState: Bool

    public init(moduleIsOn: Bool, grillTemp: Int?, grillSetTemp: Int?, fanState: Bool) {
        self.moduleIsOn = moduleIsOn
        self.grillTemp = grillTemp
        self.grillSetTemp = grillSetTemp
        self.fanState = fanState
    }

    /// Reads the machine's inputs off a live grill state.
    public init(state: GrillState) {
        self.init(moduleIsOn: state.moduleIsOn == true,
                  grillTemp: state.grillTemp,
                  grillSetTemp: state.grillSetTemp,
                  fanState: state.fanState == true)
    }
}

public struct ShutdownStep: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case cool, off }
    public struct Notice: Equatable, Sendable {
        public let title: String
        public let body: String
    }

    public let phase: ShutdownPhase?
    public let action: Action?
    public let notice: Notice?
}

public struct ShutdownConfig: Equatable, Sendable {
    /// Above this, ramp down before powering off.
    public let coolAbove: Int
    /// Ramp-down setpoint.
    public let coolTarget: Int
    /// Once at/below this, proceed to power off.
    public let coolDoneAt: Int
    /// How long before the cook is warned the cool-down hasn't finished.
    public let stallSeconds: TimeInterval

    public static let standard = ShutdownConfig(
        coolAbove: 250, coolTarget: 200, coolDoneAt: 210, stallSeconds: 30 * 60)

    public init(coolAbove: Int, coolTarget: Int, coolDoneAt: Int, stallSeconds: TimeInterval) {
        self.coolAbove = coolAbove
        self.coolTarget = coolTarget
        self.coolDoneAt = coolDoneAt
        self.stallSeconds = stallSeconds
    }
}

public enum Shutdown {
    /// The first step when the cook asks to shut down.
    public static func begin(_ input: ShutdownInput,
                             config: ShutdownConfig = .standard) -> ShutdownStep {
        if input.moduleIsOn, let temp = input.grillTemp, temp > config.coolAbove {
            return ShutdownStep(
                phase: .cooling,
                action: .cool,
                notice: .init(
                    title: "Cooling down before shutdown",
                    body: "Bringing the grill from \(temp)° to \(config.coolTarget)° first — this prevents a hopper flare-up."))
        }
        return ShutdownStep(
            phase: .finishing,
            action: .off,
            notice: .init(
                title: "Shutting down",
                body: "Turning the grill off; the fan will run until the firepot cools."))
    }

    /// Advances the machine on each fresh grill state.
    public static func advance(_ phase: ShutdownPhase?,
                               _ input: ShutdownInput,
                               config: ShutdownConfig = .standard) -> ShutdownStep {
        switch phase {
        case .cooling:
            if let temp = input.grillTemp, temp <= config.coolDoneAt {
                return ShutdownStep(
                    phase: .finishing,
                    action: .off,
                    notice: .init(
                        title: "Cooled — shutting down",
                        body: "The grill is down to temp; turning it off. The fan will run until the firepot cools."))
            }
            return ShutdownStep(phase: .cooling, action: nil, notice: nil)

        case .finishing:
            // Fully off (module off AND cool-down fan stopped) — done.
            if !input.moduleIsOn && !input.fanState {
                return ShutdownStep(phase: nil, action: nil, notice: nil)
            }
            return ShutdownStep(phase: .finishing, action: nil, notice: nil)

        case nil:
            return ShutdownStep(phase: nil, action: nil, notice: nil)
        }
    }

    /// Cooling progress as a 0…1 fraction, from the temp cooling started at.
    public static func coolProgress(from coolFrom: Int,
                                    current: Int,
                                    config: ShutdownConfig = .standard) -> Double {
        let span = Double(coolFrom - config.coolTarget)
        guard span > 0 else { return 1 }
        return max(0, min(1, Double(coolFrom - current) / span))
    }
}

/// What the cook asked for.
public enum ShutdownMode: Equatable, Sendable {
    /// Cool down first if hot, then power off.
    case auto
    /// Skip the cool-down — an explicit second press.
    case now
    /// Abort the shutdown and keep cooking.
    case cancel
}
