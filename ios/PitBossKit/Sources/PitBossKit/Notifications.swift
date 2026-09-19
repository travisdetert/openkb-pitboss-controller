import Foundation
import UserNotifications

/// Local notifications for grill alerts.
///
/// The point of the whole app is being able to walk away from a long smoke, so
/// an alert that only exists inside a foregrounded app is nearly useless. This
/// posts the same events the in-app banners show, but to the lock screen.
///
/// It relies on the `bluetooth-central` background mode keeping the app alive
/// while it holds the BLE link — without that, iOS suspends the app and no
/// alert can be raised at all.
public final class GrillNotifier: @unchecked Sendable {
    public static let shared = GrillNotifier()

    /// Set by the app from its scene phase. While the app is on screen the
    /// in-app banner already says it, and a second copy on the lock screen is
    /// noise.
    public var isForeground = true

    private var authorized = false
    private let center = UNUserNotificationCenter.current()

    private init() {}

    /// Asks for permission. Safe to call more than once.
    ///
    /// Called when a grill is first connected rather than at launch: the prompt
    /// then arrives with obvious context ("this is the grill app, and it wants
    /// to tell me about the grill") instead of before anything has happened.
    public func requestAuthorization() async {
        do {
            authorized = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            PitBossLog.write("[notify] authorization \(authorized ? "granted" : "denied")")
        } catch {
            authorized = false
            PitBossLog.write("[notify] authorization failed: \(error.localizedDescription)")
        }
    }

    /// Posts an alert, unless the app is on screen to show it itself.
    public func post(_ alert: GrillAlert) {
        guard !isForeground else { return }
        post(title: alert.kind.title, body: alert.kind.message,
             critical: alert.kind.isUrgent)
    }

    /// Identifier prefix for method-stage notifications, so they can be
    /// replaced wholesale rather than accumulating.
    private static let stagePrefix = "method-stage-"

    /// Schedules a notification for each upcoming stage of a method.
    ///
    /// These are **scheduled**, not posted: the stages are hours apart, and a
    /// reminder that only fires while the app happens to be running is no use
    /// for a 6-hour rib cook. iOS delivers these even if the app is killed.
    ///
    /// Unlike alerts, these are *not* suppressed in the foreground — a timer
    /// going off is worth seeing either way.
    public func scheduleMethodStages(
        _ stages: [(offset: TimeInterval, title: String, body: String)]) {
        cancelMethodStages()
        guard authorized else { return }

        for (index, stage) in stages.enumerated() where stage.offset > 0 {
            let content = UNMutableNotificationContent()
            content.title = stage.title
            content.body = stage.body
            content.sound = .default
            if #available(iOS 15.0, *) { content.interruptionLevel = .timeSensitive }

            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: stage.offset,
                                                            repeats: false)
            let request = UNNotificationRequest(identifier: "\(Self.stagePrefix)\(index)",
                                                content: content, trigger: trigger)
            center.add(request) { error in
                if let error {
                    PitBossLog.write("[notify] stage schedule failed: \(error.localizedDescription)")
                }
            }
        }
        PitBossLog.write("[notify] scheduled \(stages.filter { $0.offset > 0 }.count) method stage(s)")
    }

    public func cancelMethodStages() {
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(Self.stagePrefix) }
            guard !ids.isEmpty else { return }
            self.center.removePendingNotificationRequests(withIdentifiers: ids)
            PitBossLog.write("[notify] cancelled \(ids.count) pending method stage(s)")
        }
    }

    public func post(title: String, body: String, critical: Bool = false) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // Time-sensitive so a fire-safety alert can break through a Focus mode;
        // an ordinary "probe is done" should not.
        content.sound = critical ? .defaultCritical : .default
        if critical, #available(iOS 15.0, *) {
            content.interruptionLevel = .timeSensitive
        }

        // nil trigger = deliver now.
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        center.add(request) { error in
            if let error {
                PitBossLog.write("[notify] failed: \(error.localizedDescription)")
            }
        }
    }
}

extension GrillAlert.Kind {
    /// Short heading for a notification; the message is the body.
    public var title: String {
        switch self {
        case .probeReachedTarget(_, let name, _, _): return "\(name) is done"
        case .probeOverTarget(_, let name, _, _):    return "\(name) is over target"
        case .outOfPellets:                          return "Out of pellets"
        case .overTemperature:                       return "Over temperature"
        case .componentError:                        return "Grill error"
        case .shutdownNotice(let title, _):          return title
        case .primeStopFailed:                       return "Primer may still be running"
        case .flareup:                               return "Flare-up"
        case .lidOpen:                               return "Lid open?"
        case .starvingFire:                          return "Fire is starving"
        }
    }

    /// Whether this should break through a Focus mode. Reserved for the
    /// fire-safety and food-ruining cases — everything being urgent is the same
    /// as nothing being urgent.
    public var isUrgent: Bool {
        switch self {
        case .flareup, .overTemperature, .primeStopFailed, .componentError:
            return true
        case .probeOverTarget:
            return true
        case .probeReachedTarget, .outOfPellets, .shutdownNotice, .lidOpen, .starvingFire:
            return false
        }
    }
}
