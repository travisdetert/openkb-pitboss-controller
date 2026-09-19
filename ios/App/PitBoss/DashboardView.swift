import SwiftUI
import PitBossKit

/// The live cook: temperatures, what the grill is doing, and the controls.
struct DashboardView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @ObservedObject var controller: GrillController

    @State private var cookStarted: Date?
    @State private var showDiagnostics = false
    @State private var showHistory = false
    /// Probe whose settings sheet is open.
    @State private var editingProbe: Int?
    @State private var editingGrill = false
    @AppStorage("themePreference") private var themeRaw = ThemePreference.system.rawValue
    @State private var confirmPrime = false
    @State private var confirmShutdown = false
    @State private var showHopper = false
    @State private var showChecklist = false
    @State private var showCalibration = false
    @State private var showStartCook = false
    @State private var showMethodDetail = false
    @State private var pendingError: String?

    private var state: GrillState { controller.state }
    private var isRunning: Bool { state.moduleIsOn == true }

    var body: some View {
        // Landscape on a phone is wide and short: stacking everything leaves a
        // squashed chart under a row of tiles and most of the width empty. Side
        // by side gives the curve real height and keeps the readouts visible.
        GeometryReader { proxy in
            let isWide = proxy.size.width > proxy.size.height && proxy.size.width > 640
            if isWide { landscapeBody } else { portraitBody }
        }
        .background(theme.background)
        .navigationTitle(model.grillName.isEmpty ? "Pit Boss" : model.grillName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("Start a cook…") { showStartCook = true }
                    Button("Pre-cook checklist") { showChecklist = true }
                    Button("Grate calibration") { showCalibration = true }
                    Button("Cook history") { showHistory = true }
                    Button("Diagnostics") { showDiagnostics = true }
                    Picker("Appearance", selection: $themeRaw) {
                        ForEach(ThemePreference.allCases) { pref in
                            Text(pref.label).tag(pref.rawValue)
                        }
                    }
                    Divider()
                    if controller.ladderSummary != nil {
                        Button("Forget learned setpoints") { controller.forgetLadder() }
                    }
                    Button("Disconnect") { controller.disconnect() }
                    Button("Forget this grill", role: .destructive) { model.forget() }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if controller.profile?.hasLights == true {
                    Button {
                        run { try await controller.setLight(state.lightState != true) }
                    } label: {
                        Image(systemName: state.lightState == true ? "lightbulb.fill" : "lightbulb")
                    }
                    .accessibilityLabel(state.lightState == true ? "Light off" : "Light on")
                }
                Button {
                    // Priming a lit grill is usually a no-op, so warn; from idle
                    // it is routine and goes straight through, as on the desktop.
                    if controller.primingWouldBeUnusual { confirmPrime = true }
                    else { Task { await controller.primeBurst() } }
                } label: {
                    if controller.isPriming {
                        Text("\(controller.primeRemaining)s")
                            .font(.footnote.weight(.semibold).monospacedDigit())
                            .foregroundStyle(theme.green)
                    } else {
                        Image(systemName: "flame.fill")
                    }
                }
                .accessibilityLabel(controller.isPriming
                                    ? "Priming, \(controller.primeRemaining) seconds left"
                                    : "Prime auger")
                .disabled(!isLive || controller.isPriming)

                Button {
                    confirmShutdown = true
                } label: {
                    Image(systemName: "power")
                        .foregroundStyle(theme.red)
                }
                .accessibilityLabel("Turn grill off")
                // Disabled once a shutdown is running. A second `.auto` escalates
                // to skipping the cool-down — fine as the desktop's clearly
                // labelled second press, dangerous as a double-tap on an icon
                // that looks identical either way. The panel above owns the
                // escalation, where it is spelled out.
                .disabled(!isLive || controller.shutdownPhase != nil)
            }
            ToolbarItem(placement: .principal) {
                // Two lines: elapsed cook time over connection + which grill.
                // Both used to cost their own row in the content area.
                VStack(spacing: 1) {
                    SessionClock(start: controller.cookStartedAt ?? cookStarted,
                                 isRunning: isRunning)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(phaseTint)
                            .frame(width: 6, height: 6)
                        // Redrawn each second so the connect counter ticks.
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            Text(identityLine)
                                .font(.caption2)
                                .foregroundStyle(theme.textMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        Text("")
                            .font(.caption2)
                            .foregroundStyle(theme.textMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(phaseLabel). \(identityLine)")
            }
        }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
        .sheet(isPresented: $showHistory) { CookHistoryView(controller: controller) }
        .sheet(item: $editingProbe) { probe in
            ProbeSettingsView(controller: controller, probe: probe) { pendingError = $0 }
        }
        .confirmationDialog("Prime the auger?", isPresented: $confirmPrime, titleVisibility: .visible) {
            Button("Prime anyway") { Task { await controller.primeBurst() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The grill is running. Priming usually only works while it's off — e.g. to reload the firepot after running out of pellets.")
        }
        .confirmationDialog("Shut down the grill?", isPresented: $confirmShutdown, titleVisibility: .visible) {
            Button("Shut down", role: .destructive) {
                Task { await controller.requestShutdown(.auto) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Say what will actually happen: a hot grill cools first, and that
            // is the whole safety point rather than an implementation detail.
            Text(state.grillTemp.map { $0 > 250
                 ? "The grill is at \($0)°. It will cool to 200° first, then power off — this prevents a hopper flare-up."
                 : "The grill will power off and the fan will run until the firepot cools." }
                 ?? "The grill will power off and the fan will run until the firepot cools.")
        }
        .sheet(isPresented: $showHopper) { HopperView(controller: controller) }
        .sheet(isPresented: $showChecklist) { PreCookChecklist(controller: controller) }
        .sheet(isPresented: $showCalibration) { CalibrationView(controller: controller) }
        .sheet(isPresented: $showMethodDetail) {
            if let progress = controller.methodProgress {
                MethodView(method: progress.method,
                           activeSince: controller.activeMethod?.startedAt,
                           onEnd: { controller.endMethod() })
            }
        }
        .sheet(isPresented: $showStartCook) {
            StartCookView(controller: controller) { pendingError = $0 }
        }
        .sheet(isPresented: $editingGrill) {
            GrillTargetView(controller: controller) { pendingError = $0 }
        }
        .task {
            // Replaying a recorded cook: no grill, no connection attempt.
            if model.isReplaying { return }
            // Reconnect on appear when we already know the grill.
            if case .connected = controller.phase {} else {
                await controller.connect(name: model.grillName)
            }
        }
        .onAppear {
            // onChange only fires on a transition, so a cook already running
            // when this view appears would sit at 00:00:00 forever.
            if isRunning, cookStarted == nil { cookStarted = Date() }
            openSheetForCapture()
            // Once per launch, and never on top of a cook that is already
            // running — the checklist is for before you light it.
            if !model.isReplaying, !model.shownChecklistThisLaunch, !isRunning {
                model.shownChecklistThisLaunch = true
                showChecklist = true
            }
        }
        .onChange(of: isRunning) { _, running in
            // The clock tracks the burn, so it starts when the module does.
            cookStarted = running ? (cookStarted ?? Date()) : nil
        }
    }

    // MARK: - Sections

    /// Shown only when something is wrong. A healthy connection is reported by
    /// the dot in the title bar, which costs no vertical space.
    @ViewBuilder
    private var connectionNotice: some View {
        if !isLive {
            NoticeBanner(text: phaseLabel,
                         tint: {
                             if case .failed = controller.phase { return theme.red }
                             return theme.amber
                         }())
        }
    }

    /// Probes worth a tile: any that have reported, plus any with a target set.
    /// Keeping the set stable means the row doesn't collapse to a single
    /// stretched tile when nothing is connected, and a disconnected grill still
    /// shows what it is cooking to.
    private var visibleProbes: [Int] {
        Array(Set(controller.livingProbes)
            .union(controller.probeTargets.targets.filter { $0.value > 0 }.keys))
            .sorted()
    }

    private var temperatures: some View {
        let probes = visibleProbes
        let count = 1 + probes.count + (state.smokerActTemp != nil ? 1 : 0)
        // Fixed flexible columns rather than `.adaptive`: adaptive sized to the
        // tile's ideal width and wrapped three tiles onto three rows.
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8),
                            count: min(4, max(1, count)))

        return LazyVGrid(columns: columns, spacing: 8) {
            Button { editingGrill = true } label: {
                TemperatureTile(label: "Grill", value: state.grillTemp,
                                target: state.grillSetTemp, tint: theme.flame,
                                isEditable: true, placeholder: "—",
                                secondary: controller.grateTemp.map { "grate ~\($0)°" })
            }
            .buttonStyle(.plain)

            ForEach(probes, id: \.self) { probe in
                // Tapping a probe sets what you're cooking to — the tile is the
                // affordance, so there's no separate settings hunt.
                Button { editingProbe = probe } label: {
                    TemperatureTile(
                        label: controller.probeTargets.label(for: probe),
                        value: probeValue(probe),
                        target: controller.probeTargets.target(for: probe),
                        tint: probeTint(probeValue(probe),
                                        controller.probeTargets.target(for: probe)),
                        isEditable: true,
                        placeholder: "no probe",
                        secondary: etaLine(for: probe))
                }
                .buttonStyle(.plain)
            }

            if state.smokerActTemp != nil {
                TemperatureTile(label: "Smoker", value: state.smokerActTemp,
                                target: nil, tint: theme.amber)
            }
        }
    }

    /// Opens a sheet on launch so the screenshot harness can capture it.
    ///
    /// The counterpart to the desktop's `PITBOSS_SHOT_*` staging options:
    /// `PITBOSS_OPEN=grill` or `PITBOSS_OPEN=probe1`. Capture-only; it does
    /// nothing unless the variable is set.
    private func openSheetForCapture() {
        guard let what = ProcessInfo.processInfo.environment["PITBOSS_OPEN"] else { return }
        // Let the replay put some data on screen first, so the sheet opens over
        // a populated dashboard rather than an empty one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            switch what {
            case "grill": editingGrill = true
            case "shutdown": confirmShutdown = true
            case "calibration": showCalibration = true
            case "startcook": showStartCook = true
            case "prime": confirmPrime = true
            default:
                if what.hasPrefix("probe"),
                   let n = Int(what.dropFirst(5).prefix(1)) { editingProbe = n }
            }
        }
    }

    /// Notices that apply in either orientation.
    ///
    /// The connection banner is **not** here: the title bar already carries the
    /// state as a dot and a word, so in landscape — where vertical space is the
    /// scarce thing — repeating it costs a row for nothing. Portrait adds it
    /// back for the extra detail it carries (the retry countdown).
    @ViewBuilder
    private var notices: some View {
        if let resumed = controller.resumedCook {
            NoticeBanner(text: resumeMessage(resumed), tint: theme.accent) {
                controller.acknowledgeResume()
            }
        }

        ForEach(controller.alerts) { alert in
            NoticeBanner(text: alert.kind.message, tint: theme.amber) {
                controller.clearAlerts()
            }
        }
        if let pendingError {
            NoticeBanner(text: pendingError, tint: theme.red) {
                self.pendingError = nil
            }
        }
        if controller.shutdownPhase != nil {
            ShutdownPanel(controller: controller) { pendingError = $0 }
        }
    }

    private var chart: some View {
        CookChartView(samples: controller.samples,
                      probes: Array(controller.livingProbes).sorted(),
                      range: controller.temperatureRange,
                      emptyMessage: isLive
                          ? "Collecting data — the curve appears after a few readings."
                          : "Waiting for the grill. The curve resumes when it reconnects.")
    }

    private var activityPanel: some View {
        ActivityTimelineView(samples: controller.samples,
                             augerRuns: controller.runs(for: \.auger),
                             fanRuns: controller.runs(for: \.fan),
                             igniterRuns: controller.runs(for: \.igniter),
                             augerOn: state.motorState == true,
                             fanOn: state.fanState == true,
                             igniterOn: state.hotState == true,
                             primeOn: state.primeState == true,
                             lightOn: controller.profile?.hasLights == true
                                 ? state.lightState == true : nil)
            .opacity(isLive ? 1 : 0.55)
    }

    private var hopper: some View {
        Button { showHopper = true } label: { HopperBar(controller: controller) }
            .buttonStyle(.plain)
            .opacity(isLive ? 1 : 0.55)
    }

    private var portraitBody: some View {
        FillingScrollView {
            Group {
                // Portrait has the room, and the banner says more than the
                // header can: "retrying in 12s (attempt 3)".
                connectionNotice
                notices
                temperatures.opacity(isLive ? 1 : 0.55)
                methodBanner
                hopper
                chart.frame(maxHeight: .infinity)
                activityPanel
            }
        }
    }

    /// Landscape: a narrow control rail instead of a title bar.
    ///
    /// The navigation bar costs ~90pt of a 402pt-tall landscape view for a
    /// clock, a status word and two buttons — nearly a quarter of the height,
    /// spent on chrome, in the orientation with the least of it. On its side
    /// that same content fits a rail and the content keeps the full height.
    ///
    /// The readouts run full width across the top rather than being squeezed
    /// into the left column: three tiles in 360pt left the ETA wrapping onto
    /// three lines while the grill tile had room to spare.
    private var landscapeBody: some View {
        HStack(spacing: 10) {
            controlRail

            VStack(spacing: 10) {
                notices
                temperatures.opacity(isLive ? 1 : 0.55)

                // At ~380pt of usable height everything cannot stack and still
                // leave a readable curve, so the secondary panels take a side
                // column. The activity panel stretches to the column's height
                // rather than leaving a third of it empty — and the timeline is
                // genuinely easier to read with taller tracks.
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        methodBanner
                        hopper
                        activityPanel.frame(maxHeight: .infinity)
                    }
                    .frame(maxWidth: 380)

                    chart
                }
            }
            .padding(.trailing, 14)
            .padding(.vertical, 10)
        }
        // The rail replaces the title bar, so hide it rather than pay for both.
        .toolbar(.hidden, for: .navigationBar)
    }

    private var controlRail: some View {
        VStack(spacing: 14) {
            Menu {
                Button("Start a cook…") { showStartCook = true }
                Button("Pre-cook checklist") { showChecklist = true }
                Button("Grate calibration") { showCalibration = true }
                Button("Cook history") { showHistory = true }
                Button("Diagnostics") { showDiagnostics = true }
                Picker("Appearance", selection: $themeRaw) {
                    ForEach(ThemePreference.allCases) { pref in
                        Text(pref.label).tag(pref.rawValue)
                    }
                }
                Divider()
                if controller.ladderSummary != nil {
                    Button("Forget learned setpoints") { controller.forgetLadder() }
                }
                Button("Disconnect") { controller.disconnect() }
                Button("Forget this grill", role: .destructive) { model.forget() }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .accessibilityLabel("More")

            // Clock and state, stacked — the same information the title bar
            // carried, in a quarter of the vertical space.
            VStack(spacing: 4) {
                Circle()
                    .fill(phaseTint)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(phaseLabel)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(railClock)
                        .font(.system(size: 11, design: .monospaced).weight(.semibold))
                        .foregroundStyle(isRunning ? theme.text : theme.textMuted)
                        .monospacedDigit()
                }
            }

            Spacer(minLength: 0)

            if controller.profile?.hasLights == true {
                railButton(state.lightState == true ? "lightbulb.fill" : "lightbulb",
                           tint: theme.text,
                           label: state.lightState == true ? "Light off" : "Light on") {
                    run { try await controller.setLight(state.lightState != true) }
                }
            }

            if controller.isPriming {
                Text("\(controller.primeRemaining)s")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(theme.green)
            } else {
                railButton("flame.fill", tint: theme.text, label: "Prime auger") {
                    if controller.primingWouldBeUnusual { confirmPrime = true }
                    else { Task { await controller.primeBurst() } }
                }
                .disabled(!isLive)
            }

            railButton("power", tint: theme.red, label: "Turn grill off") {
                confirmShutdown = true
            }
            .disabled(!isLive || controller.shutdownPhase != nil)
        }
        .padding(.vertical, 10)
        .frame(width: 56)
        .background(theme.surface)
        .overlay(alignment: .trailing) {
            Rectangle().fill(theme.border).frame(width: 1)
        }
        .ignoresSafeArea(edges: .vertical)
    }

    /// Compact clock for the rail — hours are rare, so drop them when zero.
    private var railClock: String {
        guard let start = controller.cookStartedAt ?? cookStarted else { return "--:--" }
        let s = Int(max(0, Date().timeIntervalSince(start)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%02d:%02d", m, sec)
    }

    private func railButton(_ icon: String, tint: Color, label: String,
                            _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 40, height: 36)
        }
        .accessibilityLabel(label)
    }

    /// "~2h 40m · 4:20 PM", or the reason there's no number.
    private func etaLine(for probe: Int) -> String? {
        let verdict = controller.estimate(forProbe: probe)
        if let label = CookEstimate.label(verdict),
           let finish = CookEstimate.finishTime(verdict) {
            return "\(label) · \(finish.formatted(date: .omitted, time: .shortened))"
        }
        // Never blank: "stalled — normal, it can last hours" is information.
        return CookEstimate.explanation(verdict)
    }

    /// The method being followed, and what to do next.
    @ViewBuilder
    private var methodBanner: some View {
        if let progress = controller.methodProgress {
            Button { showMethodDetail = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: progress.isFinished ? "checkmark.circle.fill" : "list.number")
                        .foregroundStyle(progress.isFinished ? theme.green : theme.flame)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(progress.method.name) · \(progress.step.title)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(theme.text)
                        Text(progress.isFinished
                             ? "Finished — check it"
                             : (progress.remainingLabel ?? progress.step.detail))
                            .font(.caption2)
                            .foregroundStyle(theme.textMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2).foregroundStyle(theme.textMuted)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    private func resumeMessage(_ cook: CookMeta) -> String {
        let started = cook.startedAt.formatted(date: .omitted, time: .shortened)
        let breaks = cook.events.filter(\.kind.interruptedTheCook).count
        var text = "Picked up your cook from \(started) — \(cook.sampleCount) readings kept."
        if breaks > 0 {
            text += " \(breaks) interruption\(breaks == 1 ? "" : "s") recorded."
        }
        return text
    }

    // MARK: - Helpers

    /// Runs a command and surfaces a failure instead of swallowing it — a
    /// control that silently did nothing is worse than one that says why.
    private func run(_ body: @escaping () async throws -> Void) {
        Task {
            do { try await body() } catch { pendingError = error.localizedDescription }
        }
    }

    private func probeValue(_ probe: Int) -> Int? {
        switch probe {
        case 1: return state.p1Temp
        case 2: return state.p2Temp
        case 3: return state.p3Temp
        default: return state.p4Temp
        }
    }

    private func probeTint(_ value: Int?, _ target: Int?) -> Color {
        guard let value, let target else { return theme.accent }
        return value >= target ? theme.green : theme.accent
    }

    private var phaseTint: Color {
        switch controller.phase {
        case .connected:              return theme.green
        case .connecting, .scanning:  return theme.amber
        case .reconnecting, .awaitingReconnect: return theme.amber
        case .failed:                 return theme.red
        case .idle:                   return theme.inactive
        }
    }

    /// "Connected · PB1100PSC3" — the model once deduced, the board until then.
    private var identityLine: String {
        var parts = [shortPhase]
        if let identity = controller.grillIdentity { parts.append(identity) }
        return parts.joined(separator: " · ")
    }

    private var shortPhase: String {
        switch controller.phase {
        case .connected:    return "Connected"
        case .connecting:
            // Count up: a weak link can take over a minute, and a static label
            // for that long reads as a hang.
            if let since = controller.connectingSince {
                let seconds = Int(Date().timeIntervalSince(since))
                if seconds >= 5 { return "Connecting \(seconds)s" }
            }
            return "Connecting"
        case .scanning:     return "Scanning"
        case .reconnecting, .awaitingReconnect: return "Reconnecting"
        case .idle:         return "Offline"
        case .failed:       return "Disconnected"
        }
    }

    private var phaseLabel: String {
        switch controller.phase {
        case .connected:          return "Connected"
        case .connecting:         return "Connecting…"
        case .scanning:           return "Scanning…"
        case .idle:               return "Not connected"
        case .failed(let m):      return m
        case .reconnecting(let attempt, let seconds):
            // Say what is happening and when the next try is, rather than a
            // spinner that could equally mean "hung".
            return "Lost the grill — retrying in \(seconds)s (attempt \(attempt))"
        case .awaitingReconnect:
            // No countdown: this one is held by the system and completes on its
            // own, so promising a retry in N seconds would be a worse answer,
            // not a more precise one.
            return "Out of range — will reconnect on its own, even if you close the app"
        }
    }

    /// Readings go stale the moment the link drops; dim them rather than
    /// presenting a frozen number as if it were live.
    private var isLive: Bool {
        if case .connected = controller.phase { return true }
        return false
    }
}
