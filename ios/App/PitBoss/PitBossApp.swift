import SwiftUI
import PitBossKit

@main
struct PitBossApp: App {
    @StateObject private var model = AppModel()

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootContainer().environmentObject(model)
        }
        // The notifier suppresses banners while the app is on screen, where the
        // in-app notice already says it. This is the one place that knows.
        .onChange(of: scenePhase) { _, phase in
            GrillNotifier.shared.isForeground = (phase == .active)
            PitBossLog.write("[app] scene \(String(describing: phase))")
            // Coming back to the foreground is the app's only chance to notice
            // that a connect issued before it was suspended never completed —
            // no timer of ours ran while it was away.
            if phase == .active {
                Task { await model.controller?.recycleStaleConnect() }
            }
        }
    }
}

/// Resolves the active theme and hands it down.
///
/// This has to be a `View`, not the `App`: `@Environment(\.colorScheme)` read on
/// an `App` does not reflect the system appearance — it silently returns the
/// default, which pinned the whole UI to the light palette no matter what the OS
/// was doing. Reading it here is what makes "follow the system" actually work.
struct RootContainer: View {
    @AppStorage("themePreference") private var themeRaw = ThemePreference.system.rawValue
    @Environment(\.colorScheme) private var systemScheme

    private var preference: ThemePreference {
        ThemePreference(rawValue: themeRaw) ?? .system
    }

    var body: some View {
        // The toggle wins; the OS is the fallback. When the preference is
        // .system, `preferredColorScheme(nil)` imposes nothing, so `systemScheme`
        // is the real appearance and there is no feedback loop.
        let effective = preference.colorScheme ?? systemScheme
        RootView()
            .environment(\.theme, effective == .dark ? .dark : .light)
            .preferredColorScheme(preference.colorScheme)
            // The navigation bar is UIKit and styles its title from the scheme
            // it thinks it is in — without this the large title rendered white
            // on the light background.
            .toolbarColorScheme(effective, for: .navigationBar)
    }
}

/// Owns the controller and the one piece of state the app needs before it can
/// connect: which grill, and which model's parsing routines to use.
@MainActor
final class AppModel: ObservableObject {
    @Published var controller: GrillController?
    @Published var setupError: String?

    /// Remembered so a returning cook lands straight on the dashboard. The
    /// name is the whole configuration — the control board follows from it.
    @AppStorage("grillName") var grillName = ""

    let catalog: GrillCatalog?

    init() {
        // Resolved into locals first: `catalog` is a `let`, so it has to be
        // assigned exactly once regardless of which branch runs.
        var catalog: GrillCatalog?
        var controller: GrillController?
        var setupError: String?
        do {
            let loaded = try GrillCatalog.bundled()
            catalog = loaded
            controller = try GrillController(catalog: loaded)
            PitBossLog.write("[app] launched — \(loaded.count) grill models available")
        } catch {
            setupError = error.localizedDescription
            PitBossLog.write("[app] failed to start: \(error)")
        }
        self.catalog = catalog
        self.controller = controller
        self.setupError = setupError
        // Must happen before the first render: RootView decides between setup
        // and the dashboard on `isConfigured`, which replay satisfies.
        startReplayIfRequested()
    }

    /// Set when the app was launched to replay a recorded cook instead of
    /// talking to a grill (PITBOSS_REPLAY). Used to inspect and capture the UI.
    private(set) var isReplaying = false
    /// The pre-cook checklist shows once per launch, not on every view appear.
    var shownChecklistThisLaunch = false

    var isConfigured: Bool { isReplaying || !grillName.isEmpty }

    /// Starts replay if the environment asks for it. Returns true when it did.
    @discardableResult
    func startReplayIfRequested() -> Bool {
        guard !isReplaying, let source = ReplaySource.fromEnvironment(),
              let controller else { return false }
        isReplaying = true
        controller.startReplay(source)
        return true
    }

    func forget() {
        controller?.disconnect()
        grillName = ""
    }
}
