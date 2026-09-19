import Foundation

/// Cleaning/maintenance tracking — a port of `src/main/maintenance.ts`.
///
/// Why flare-ups count toward cleaning: a large temperature spike well above the
/// setpoint usually means a grease fire in the barrel. Repeated flare-ups mean
/// grease has built up and the drip tray / grease bucket need emptying. That is
/// a fire-safety matter, not housekeeping.
public struct MaintenanceState: Codable, Equatable, Sendable {
    public var cooksSinceClean: Int
    public var runSecondsSinceClean: Double
    public var flareupsSinceClean: Int
    public var cleanedAt: Date?

    public static let fresh = MaintenanceState(
        cooksSinceClean: 0, runSecondsSinceClean: 0, flareupsSinceClean: 0, cleanedAt: nil)

    public init(cooksSinceClean: Int = 0, runSecondsSinceClean: Double = 0,
                flareupsSinceClean: Int = 0, cleanedAt: Date? = nil) {
        self.cooksSinceClean = cooksSinceClean
        self.runSecondsSinceClean = runSecondsSinceClean
        self.flareupsSinceClean = flareupsSinceClean
        self.cleanedAt = cleanedAt
    }

    private static let key = "maintenanceState"

    public static func load(from defaults: UserDefaults = .standard) -> MaintenanceState {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(MaintenanceState.self, from: data)
        else { return .fresh }
        return value
    }

    public func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

public struct MaintenanceThresholds: Equatable, Sendable {
    public let afterCooks: Int
    public let afterHours: Double
    public let afterFlareups: Int
    /// Degrees above the setpoint that counts as a flare-up.
    public let flareMargin: Int

    public static let standard = MaintenanceThresholds(
        afterCooks: 5, afterHours: 30, afterFlareups: 3, flareMargin: 100)
}

public enum Maintenance {
    /// Human-readable reasons a cleaning is recommended. Empty means not due.
    public static func reasons(_ m: MaintenanceState,
                               thresholds t: MaintenanceThresholds = .standard) -> [String] {
        var reasons: [String] = []
        if m.cooksSinceClean >= t.afterCooks { reasons.append("\(m.cooksSinceClean) cooks") }
        let hours = m.runSecondsSinceClean / 3600
        if hours >= t.afterHours { reasons.append("\(Int(hours.rounded()))h of use") }
        if m.flareupsSinceClean >= t.afterFlareups { reasons.append("\(m.flareupsSinceClean) flare-ups") }
        return reasons
    }

    public static func isDue(_ m: MaintenanceState,
                             thresholds t: MaintenanceThresholds = .standard) -> Bool {
        !reasons(m, thresholds: t).isEmpty
    }

    /// A flare-up: the grill reads well above its setpoint while running.
    /// Judged only when both temperatures are known and the grill is on.
    public static func isFlareup(grillTemp: Int?, grillSetTemp: Int?, moduleIsOn: Bool,
                                 thresholds t: MaintenanceThresholds = .standard) -> Bool {
        guard moduleIsOn, let temp = grillTemp, let set = grillSetTemp else { return false }
        return temp > set + t.flareMargin
    }
}
