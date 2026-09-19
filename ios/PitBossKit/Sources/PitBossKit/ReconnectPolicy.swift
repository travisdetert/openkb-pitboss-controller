import Foundation

/// How long to wait between reconnect attempts.
///
/// Extracted from the loop so the ladder is a value that can be checked rather
/// than timing behaviour that can only be observed. Mirrors the desktop
/// sidecar's `_reconnect_loop`: start at 3s, double, cap at 30s.
///
/// The cap matters more than it looks. A grill cook runs for hours, and a phone
/// that wandered out of range should rejoin within half a minute of coming back
/// — not back off to minutes the way a server-to-server client would.
public struct ReconnectPolicy: Sendable, Equatable {
    public let initialDelay: Int
    public let maximumDelay: Int
    public let multiplier: Int

    public static let standard = ReconnectPolicy(initialDelay: 3, maximumDelay: 30, multiplier: 2)

    public init(initialDelay: Int = 3, maximumDelay: Int = 30, multiplier: Int = 2) {
        self.initialDelay = max(1, initialDelay)
        // Clamp against the *clamped* floor, not the raw argument: using the
        // parameter here let a bad maximum drop below 1 and produce zero-delay
        // retries, i.e. a tight loop against the Bluetooth radio.
        self.maximumDelay = max(self.initialDelay, maximumDelay)
        self.multiplier = max(2, multiplier)
    }

    /// Delay before `attempt`, counting from 1.
    public func delay(forAttempt attempt: Int) -> Int {
        guard attempt > 1 else { return initialDelay }
        var delay = initialDelay
        for _ in 1..<attempt {
            delay = min(delay * multiplier, maximumDelay)
            if delay == maximumDelay { break }
        }
        return delay
    }

    /// The first `count` delays, for display and for checking.
    public func ladder(_ count: Int) -> [Int] {
        (1...max(1, count)).map(delay(forAttempt:))
    }
}
