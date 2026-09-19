import Foundation

/// How the app is currently placed relative to the grill.
public enum ConnectionPhase: Equatable, Sendable {
    case idle
    case scanning
    case connecting
    case connected
    /// Link dropped but we still want it: retrying with backoff. Used when the
    /// app has to drive the retry itself — a connect that never established.
    case reconnecting(attempt: Int, seconds: Int)
    /// Link dropped and the *system* is holding the reconnect for us. Distinct
    /// from `.reconnecting` because it is a different promise to the cook: it
    /// completes on its own, with the phone locked and the app in the
    /// background, so there is no countdown to show and nothing to retry.
    case awaitingReconnect
    case failed(String)
}

/// The high-level grill API, mirroring `pytboss/api.py` and the command surface
/// the desktop app's sidecar exposes (`set_temp`, `set_probe`, `light`,
/// `prime`, `off`, `refresh`).
///
/// Observable so SwiftUI can bind to it directly. Everything that touches
/// published state hops to the main actor; the BLE work happens off it.
@MainActor
public final class GrillController: ObservableObject {

    @Published public private(set) var state = GrillState()
    @Published public private(set) var phase: ConnectionPhase = .idle
    /// Capabilities derived from the detected control board. No model needed.
    @Published public private(set) var profile: BoardProfile?
    /// Probes that have actually reported a reading — the fitted count, observed
    /// rather than assumed from a model number.
    @Published public private(set) var livingProbes: Set<Int> = []
    @Published public private(set) var discovered: [DiscoveredGrill] = []
    /// Set when a probe target is hit, pellets run out, or the board errors.
    @Published public private(set) var alerts: [GrillAlert] = []

    // MARK: Graceful shutdown
    /// Non-nil while a shutdown is in progress.
    @Published public private(set) var shutdownPhase: ShutdownPhase?
    /// Temperature the cool-down started from, for the progress readout.
    @Published public private(set) var shutdownCoolFrom = 0
    /// True once the cool-down has run past the stall threshold.
    @Published public private(set) var shutdownStalled = false

    // MARK: Cook history
    /// Recorded points behind the charts and the activity timeline.
    @Published public private(set) var samples: [CookSample] = []
    private let history = CookHistory()
    private let cookStore: CookStore
    private var wasModuleOn = false

    /// Cooks recorded to disk, newest first.
    public func listCooks() -> [CookMeta] { cookStore.listCooks() }
    public func readCook(_ id: String) throws -> [CookSample] { try cookStore.readCook(id) }
    public func deleteCook(_ id: String) throws { try cookStore.deleteCook(id) }
    public func renameCook(_ id: String, to name: String) throws { try cookStore.renameCook(id, to: name) }

    /// Records a fresh state into the live curve and, when the interval is up,
    /// to disk.
    ///
    /// **A cook is the food, not the fire.** The grill going off does not end
    /// the cook — a pellet outage, a relight, or a flat phone battery all stop
    /// the recording for a while without the brisket coming off. Each is
    /// written into the file as an interruption and the same cook continues,
    /// so the record shows the whole thing with the gaps visible rather than
    /// being split into fragments that lose the shape of it.
    ///
    /// The cook is only closed once the grill has been off longer than
    /// `interruptionGrace`, or when it's ended deliberately.
    private func recordHistory(_ state: GrillState) {
        let on = state.moduleIsOn == true
        let now = Date()

        if on && !wasModuleOn {
            if cookStore.activeCookID != nil {
                // Same cook, relit after an interruption.
                record(CookEvent(at: now, kind: .grillOn))
                grillOffSince = nil
            } else {
                cookStore.startCook(device: connectedName)
                history.clear()
                samples = []
                cookEvents = []
            }
        } else if !on && wasModuleOn {
            // Off, but not necessarily over.
            record(CookEvent(at: now, kind: .grillOff))
            grillOffSince = now
        }
        wasModuleOn = on

        // Close the cook only once it's clearly not coming back.
        if !on, let offSince = grillOffSince, cookStore.activeCookID != nil,
           now.timeIntervalSince(offSince) > CookStore.interruptionGrace {
            cookStore.endCook()
            countCook()
            grillOffSince = nil
        }

        if history.record(state) {
            samples = history.samples
            // Append as we go: a crash, or iOS killing a backgrounded app,
            // then costs the last interval rather than the whole cook.
            if let latest = history.samples.last { cookStore.append(latest) }
        }
    }

    /// When the grill went off, for deciding interruption vs. end.
    private var grillOffSince: Date?

    /// Interruptions recorded during the live cook, for the estimate and the UI.
    @Published public private(set) var cookEvents: [CookEvent] = []

    private func record(_ event: CookEvent) {
        cookEvents.append(event)
        cookStore.append(event: event)
    }

    /// Time until a probe reaches its target, accounting for the stall and for
    /// pellet outages recorded during this cook.
    public func estimate(forProbe probe: Int) -> CookEstimate.Verdict {
        CookEstimate.estimate(samples: samples, probe: probe,
                              target: probeTargets.target(for: probe),
                              events: cookEvents)
    }

    /// Picks up an unfinished cook after the app was restarted.
    ///
    /// The app being killed — a flat battery, a force quit, iOS reclaiming a
    /// backgrounded app, or a reinstall while developing — is a disruption to
    /// the *record*, not to the cook. Resuming keeps one continuous file and
    /// annotates the break rather than starting a second one.
    private func resumeCookIfAny() {
        guard cookStore.activeCookID == nil,
              let resumable = cookStore.resumableCook() else { return }
        do {
            let existing = try cookStore.resume(resumable.id)
            cookEvents = resumable.events
            history.resume(with: existing)
            samples = history.samples
            wasModuleOn = true
            record(CookEvent(at: Date(), kind: .appResumed))
            resumedCook = resumable
            PitBossLog.write("[cook] resumed \(resumable.id) — \(existing.count) samples, started \(resumable.startedAt)")
        } catch {
            PitBossLog.write("[cook] could not resume \(resumable.id): \(error.localizedDescription)")
        }
    }

    /// Set when a cook was picked up after a restart, so the UI can say so.
    @Published public private(set) var resumedCook: CookMeta?

    /// When the active cook began — survives restarts and grill power cycles,
    /// so the session clock shows the true elapsed cook.
    public var cookStartedAt: Date? { cookStore.activeStartedAt }

    public func acknowledgeResume() { resumedCook = nil }

    /// Ends the cook deliberately, even if the grill is still on.
    public func endCookNow() {
        guard cookStore.activeCookID != nil else { return }
        cookStore.endCook()
        countCook()
        grillOffSince = nil
        history.clear()
        samples = []
        PitBossLog.write("[cook] ended by request")
    }

    /// Contiguous runs where a component was active, for the timeline.
    public func runs(for component: KeyPath<CookSample, Bool>) -> [(start: Date, end: Date)] {
        history.runs(for: component)
    }

    /// Y-axis bounds across grill, setpoint and probes.
    public var temperatureRange: ClosedRange<Int>? { history.temperatureRange }

    // MARK: Probe targets
    /// Per-probe targets and names. Kept app-side for every probe, because most
    /// boards can only be told about probe 1 (see ProbeTargets).
    @Published public private(set) var probeTargets = ProbeTargets.load()
    private var probeLatches = ProbeAlerting.Latches()

    /// Whether the grill itself can be given a target for this probe.
    public func supportsHardwareTarget(probe: Int) -> Bool {
        board?.commands["set-probe-\(probe)-temperature"] != nil
    }

    /// Sets a probe's target.
    ///
    /// The target is always stored and always drives alerting. It is *also*
    /// pushed to the grill when the board has a command for that probe —
    /// returns true when it was. A false return is not an error: PBL simply has
    /// no probe-2 target, and the app watching it is the whole point.
    @discardableResult
    public func setProbeTarget(probe: Int, value: Int) async throws -> Bool {
        probeTargets.targets[probe] = value
        probeTargets.save()
        // Re-arm so a new target can alert even if the old one had fired.
        probeLatches = ProbeAlerting.Latches()

        guard supportsHardwareTarget(probe: probe) else {
            PitBossLog.write("[probe] \(probe) target \(value)° (app-side; board has no probe-\(probe) command)")
            return false
        }
        try await send("set-probe-\(probe)-temperature", [value])
        return true
    }

    public func setProbeLabel(probe: Int, name: String) {
        probeTargets.labels[probe] = name
        probeTargets.save()
    }

    public func clearProbeTarget(probe: Int) {
        probeTargets.targets[probe] = nil
        probeTargets.save()
    }

    // MARK: Ladder learning
    /// What the grill has done with setpoints we asked for, persisted per grill.
    @Published public private(set) var ladderObservations: [SetpointObservation] = []
    private var pendingSetpoint: (value: Int, at: Date)?

    /// How long to wait before concluding the grill refused a setpoint. The
    /// first frame after a request often still carries the previous value, so
    /// calling it refused immediately would manufacture false observations.
    private static let setpointSettleSeconds: TimeInterval = 20

    /// Which of the board's ladders the cook picked, if any.
    @Published public private(set) var chosenLadder: [Int]?

    /// Setpoints to offer.
    ///
    /// The cook's explicit choice wins; otherwise the board's default ladder
    /// (the shortest — see `BoardProfile`). Either way, observation still
    /// applies: a setpoint the grill demonstrably refused is dropped, and one
    /// it accepted is added even if no catalogue ladder lists it.
    public var presets: [Int] {
        guard let profile else { return [] }
        var values = Set(chosenLadder ?? profile.presets)
        values.formUnion(ladderObservations.filter(\.accepted).map(\.requested))
        for refused in ladderObservations.filter({ !$0.accepted }).map(\.requested) {
            values.remove(refused)
        }
        return values.filter { $0 >= profile.minTemp && $0 <= profile.maxTemp }.sorted()
    }

    /// The ladders this board's models use, for the chooser.
    public var ladderOptions: [[Int]] { profile?.ladderOptions ?? [] }

    public func chooseLadder(_ ladder: [Int]) {
        chosenLadder = ladder
        if let name = connectedName {
            UserDefaults.standard.set(ladder, forKey: "ladder.chosen.\(name)")
        }
        PitBossLog.write("[ladder] chosen \(ladder.count)-step ladder")
    }

    /// Plain-language note on what has been narrowed, or nil before anything is known.
    public var ladderSummary: String? {
        guard let profile else { return nil }
        return LadderInference.summary(candidates: catalog.allGrills(controlBoard: profile.board),
                                       observations: ladderObservations)
    }

    /// What to call this grill: the exact model once observation has narrowed
    /// to one, otherwise the control board it advertised.
    ///
    /// The firmware never reports a model (ADR 0003), so a specific model name
    /// here means it was *deduced* from the setpoints the grill accepted — not
    /// read off the device.
    public var grillIdentity: String? {
        guard let profile else { return nil }
        let candidates = catalog.allGrills(controlBoard: profile.board)
        let surviving = LadderInference.narrow(candidates: candidates,
                                               observations: ladderObservations)
        return surviving.count == 1 ? surviving[0].name : profile.board
    }

    /// True when `grillIdentity` is an exact model rather than a board.
    public var identityIsExact: Bool {
        guard let profile else { return false }
        let candidates = catalog.allGrills(controlBoard: profile.board)
        return LadderInference.narrow(candidates: candidates,
                                      observations: ladderObservations).count == 1
    }

    public func forgetLadder() {
        guard let name = connectedName else { return }
        LadderMemory.clear(grill: name)
        ladderObservations = []
        PitBossLog.write("[ladder] observations cleared")
    }

    /// Compares the grill's reported setpoint against what we last asked for.
    ///
    /// Acceptance is concluded as soon as the reported value matches. Refusal
    /// needs the settle window to elapse first — otherwise a frame that simply
    /// predates the command would be recorded as a refusal.
    private func noteSetpoint(_ reported: Int?) {
        guard let reported, let pending = pendingSetpoint, let name = connectedName else { return }

        if reported == pending.value {
            pendingSetpoint = nil
            record(SetpointObservation(requested: pending.value, reported: reported), grill: name)
        } else if Date().timeIntervalSince(pending.at) > Self.setpointSettleSeconds {
            pendingSetpoint = nil
            record(SetpointObservation(requested: pending.value, reported: reported), grill: name)
        }
    }

    private func record(_ observation: SetpointObservation, grill: String) {
        PitBossLog.write("[ladder] requested \(observation.requested)° → grill reports \(observation.reported)° — \(observation.accepted ? "accepted" : "REFUSED")")
        ladderObservations = LadderMemory.record(observation, grill: grill)
        if let summary = ladderSummary { PitBossLog.write("[ladder] \(summary)") }
    }

    // MARK: Pellets
    /// Estimated hopper level, from cumulative auger run-time.
    @Published public private(set) var pellets = PelletState.load()
    private var lastAugerTick: Date?
    private var lastPelletSave: Date?

    public var pelletPercent: Double { PelletEstimate.percent(pellets) }
    public var pelletPoundsLeft: Double { PelletEstimate.remainingPounds(pellets) }
    public var pelletLevel: PelletEstimate.Level { PelletEstimate.level(percent: pelletPercent) }

    /// Rough hours of pellets left, or nil when it can't be said meaningfully.
    public var pelletHoursLeft: Double? {
        PelletEstimate.hoursLeft(samples: samples, state: pellets,
                                 moduleIsOn: state.moduleIsOn == true)
    }

    public func markHopperRefilled() {
        pellets = PelletEstimate.refilled(pellets)
        pellets.save()
        PitBossLog.write("[pellets] hopper refilled — estimate reset to full")
    }

    public func markHopperEmptied() {
        pellets = PelletEstimate.emptied(pellets)
        pellets.save()
        PitBossLog.write("[pellets] hopper emptied — estimate set to 0%")
    }

    public func setHopper(capacityLbs: Double, feedRateLbsPerHr: Double) {
        pellets.capacityLbs = max(1, capacityLbs)
        pellets.feedRateLbsPerHr = max(0.1, feedRateLbsPerHr)
        pellets.save()
        PitBossLog.write("[pellets] hopper \(pellets.capacityLbs) lb at \(pellets.feedRateLbsPerHr) lb/hr")
    }

    /// Integrates auger run-time between state updates.
    private func advancePellets(_ state: GrillState) {
        let now = Date()
        defer { lastAugerTick = now }
        guard let last = lastAugerTick else { return }

        pellets = PelletEstimate.advance(pellets, augerOn: state.motorState == true,
                                         since: last, now: now)
        // Throttled, like the desktop: this changes every few seconds and the
        // store is not worth writing that often.
        if lastPelletSave == nil || now.timeIntervalSince(lastPelletSave!) > 15 {
            lastPelletSave = now
            pellets.save()
        }
    }

    // MARK: Maintenance
    /// Usage since the last firepot clean — drives the pre-cook reminder.
    @Published public private(set) var maintenance = MaintenanceState.load()
    private var lastRunTick: Date?
    private var flareupLatched = false

    public var cleaningIsDue: Bool { Maintenance.isDue(maintenance) }
    public var cleaningReasons: [String] { Maintenance.reasons(maintenance) }

    public func markCleaned() {
        maintenance = .fresh
        maintenance.cleanedAt = Date()
        maintenance.save()
        PitBossLog.write("[maintenance] firepot cleaned — counters reset")
    }

    /// Accumulates run-time and flare-ups, and counts a cook when one ends.
    private func advanceMaintenance(_ state: GrillState) {
        let now = Date()
        let isOn = state.moduleIsOn == true

        if isOn, let last = lastRunTick {
            // Same clamp as the pellet integrator: a dropped link must not be
            // counted as hours of running.
            maintenance.runSecondsSinceClean += min(now.timeIntervalSince(last),
                                                    PelletEstimate.maximumTickSeconds)
        }
        lastRunTick = isOn ? now : nil

        // A flare-up is an edge, not a level: latch until the grill settles back.
        let flaring = Maintenance.isFlareup(grillTemp: state.grillTemp,
                                            grillSetTemp: state.grillSetTemp,
                                            moduleIsOn: isOn)
        if flaring, !flareupLatched {
            flareupLatched = true
            maintenance.flareupsSinceClean += 1
            maintenance.save()
            PitBossLog.write("[maintenance] flare-up #\(maintenance.flareupsSinceClean) — grill \(state.grillTemp.map(String.init) ?? "?")° vs set \(state.grillSetTemp.map(String.init) ?? "?")°")
            raise(.flareup)
        } else if !flaring {
            flareupLatched = false
        }
    }

    /// Counts a completed cook toward the cleaning cadence.
    private func countCook() {
        maintenance.cooksSinceClean += 1
        maintenance.save()
        PitBossLog.write("[maintenance] \(maintenance.cooksSinceClean) cook(s) since last clean")
    }

    // MARK: Thermal anomalies
    /// Watches for a lid left open and for a fire that is starving — both
    /// before the controller's own flags would notice.
    private let thermal = ThermalDetector()

    private func advanceThermal(_ state: GrillState) {
        for event in thermal.feed(state) {
            switch event {
            case .lidOpen(let rate, let temperature):
                raise(.lidOpen(rate: rate, temperature: temperature))
            case .starvingFire(let temperature, let setTemp):
                raise(.starvingFire(temperature: temperature, setTemp: setTemp))
            }
        }
    }

    // MARK: Grate calibration
    /// Difference between grate level and the controller's own reading, in °F.
    ///
    /// The controller's RTD sits on the barrel wall near the controller, not at
    /// grate level, so the two genuinely measure different places — a 25–50°
    /// gap is normal and is not a failed sensor.
    ///
    /// **Display only, deliberately.** Everything that makes a decision —
    /// the cool-to-200 shutdown chain, lid-open and starving-fire detection,
    /// flare-up detection, and the setpoint you send — stays on the controller's
    /// raw value, because that is the number the controller itself is acting on.
    /// Recorded cooks also store the raw value, so a cook file means the same
    /// thing whatever the offset happened to be that day.
    @Published public private(set) var grateOffset: Int = UserDefaults.standard.integer(forKey: "grateOffset")

    public func setGrateOffset(_ value: Int) {
        grateOffset = max(-100, min(100, value))
        UserDefaults.standard.set(grateOffset, forKey: "grateOffset")
        PitBossLog.write("[calibration] grate offset \(grateOffset >= 0 ? "+" : "")\(grateOffset)°")
    }

    /// Estimated temperature at grate level, or nil when no offset is set.
    public var grateTemp: Int? {
        guard grateOffset != 0, let temp = state.grillTemp else { return nil }
        return temp + grateOffset
    }

    // MARK: Cook presets
    /// What starting a cook for `cut` would actually do, resolved against this
    /// grill's own ladder. Computed separately from applying it so the UI can
    /// show the real numbers before anything is sent.
    public struct PlannedCook: Equatable, Sendable {
        public let cut: MeatCut
        public let target: MeatTarget
        public let probe: Int
        /// The setpoint the grill will actually be given.
        public let grillSetpoint: Int?
        /// The cut's recommendation, when it differs from what the grill can do.
        public let recommendedGrill: Int?

        public var grillWasAdjusted: Bool {
            guard let set = grillSetpoint, let wanted = recommendedGrill else { return false }
            return set != wanted
        }
    }

    public func planCook(cut: MeatCut, target: MeatTarget, probe: Int) -> PlannedCook {
        let wanted = cut.grillTemp
        let snapped = wanted.flatMap { MeatCatalog.nearestSetpoint(to: $0, in: presets) }
        return PlannedCook(cut: cut, target: target, probe: probe,
                           grillSetpoint: snapped, recommendedGrill: wanted)
    }

    /// Applies a planned cook: names the probe, sets its target, and sets the
    /// grill. Ordered so the probe is armed before the grill starts heating.
    public func startCook(_ plan: PlannedCook) async throws {
        PitBossLog.write("[cook] starting \(plan.cut.name) — probe \(plan.probe) → \(plan.target.temperature)°, grill → \(plan.grillSetpoint.map(String.init) ?? "unchanged")°")
        setProbeLabel(probe: plan.probe, name: plan.cut.name)
        try await setProbeTarget(probe: plan.probe, value: plan.target.temperature)
        if let setpoint = plan.grillSetpoint {
            try await setTemperature(setpoint)
        }
    }

    // MARK: Active method
    /// The method being followed for this cook, if any.
    @Published public private(set) var activeMethod: ActiveMethod?

    /// Where that method has got to right now.
    public var methodProgress: MethodProgress? {
        guard let active = activeMethod,
              let method = MeatCatalog.methods.first(where: { $0.name == active.methodName })
        else { return nil }
        return MethodTimeline.progress(method, startedAt: active.startedAt)
    }

    /// Makes a method the current cook type and schedules its stage reminders.
    public func startMethod(_ method: CookMethod, cut: MeatCut?) {
        let active = ActiveMethod(methodName: method.name, startedAt: Date(), cutName: cut?.name)
        active.save()
        activeMethod = active

        let stages = MethodTimeline.upcomingStages(method, startedAt: active.startedAt)
        GrillNotifier.shared.scheduleMethodStages(stages)
        PitBossLog.write("[method] started \(method.name)\(cut.map { " for \($0.name)" } ?? "") — \(stages.count) stage reminder(s)")

        // The method is part of the cook's story, so it belongs in the record.
        record(CookEvent(at: active.startedAt, kind: .methodStarted))
    }

    public func endMethod() {
        guard let active = activeMethod else { return }
        GrillNotifier.shared.cancelMethodStages()
        ActiveMethod.clear()
        activeMethod = nil
        PitBossLog.write("[method] ended \(active.methodName)")
    }

    /// Re-establishes stage reminders after a restart.
    ///
    /// Notifications already scheduled with iOS survive the app dying, but
    /// rescheduling is idempotent and covers the case where they were cleared —
    /// and `upcomingStages` drops anything already past, so nothing stale fires.
    private func restoreMethodIfAny() {
        guard let active = ActiveMethod.load() else { return }
        activeMethod = active
        guard let method = MeatCatalog.methods.first(where: { $0.name == active.methodName })
        else { return }
        GrillNotifier.shared.scheduleMethodStages(
            MethodTimeline.upcomingStages(method, startedAt: active.startedAt))
        PitBossLog.write("[method] restored \(active.methodName), started \(active.startedAt)")
    }

    private let shutdownConfig = ShutdownConfig.standard
    private var shutdownStartedAt: Date?

    /// 0…1 through the cool-down, or nil when not cooling.
    public var coolProgress: Double? {
        guard shutdownPhase == .cooling, let temp = state.grillTemp else { return nil }
        return Shutdown.coolProgress(from: shutdownCoolFrom, current: temp, config: shutdownConfig)
    }

    private let transport = BLETransport()
    private let catalog: GrillCatalog
    private var board: ControlBoard?
    private var pollTask: Task<Void, Never>?
    private var connectedName: String?

    /// Intent, kept separate from actual connection state — the distinction the
    /// desktop sidecar draws with `want_connected`. A grill controller that
    /// gives up the moment the cook walks out of range is useless; it should
    /// keep trying until told to stop.
    private var wantConnected = false
    private var reconnectTask: Task<Void, Never>?
    /// When the current connect attempt began, for the elapsed readout.
    @Published public private(set) var connectingSince: Date?

    /// Grill password, when one has been set on the board. Empty is the default
    /// and skips the codec path entirely.
    public var password: String = ""

    public init(catalog: GrillCatalog? = nil, cookStore: CookStore? = nil) throws {
        self.catalog = try catalog ?? GrillCatalog.bundled()
        self.cookStore = cookStore ?? CookStore()
        configureTransport()
    }

    private func configureTransport() {
        transport.onDebugFrame = { [weak self] frame in
            Task { @MainActor in self?.ingest(frame) }
        }
        transport.onDisconnect = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.pollTask?.cancel()
                self.pollTask = nil
                PitBossLog.write("[app] link lost: \(error?.localizedDescription ?? "disconnected")")
                // The record should show the gap, not hide it.
                self.record(CookEvent(at: Date(), kind: .linkLost))
                // Only give up if the cook asked us to. Otherwise this is just
                // the grill going out of range, which is expected on a long cook.
                if self.wantConnected, let name = self.connectedName {
                    // Division of labour: a link that was once up is recovered
                    // by the system-held connect, which works while suspended.
                    // The app ladder is only for the case the system cannot
                    // cover — no peripheral to re-arm — because two connects
                    // racing on one peripheral is how the backstop ends up
                    // cancelling the primary and nothing reconnects at all.
                    if self.transport.hasStandingReconnect {
                        PitBossLog.write("[app] waiting on the standing reconnect — no retry ladder")
                        self.phase = .awaitingReconnect
                    } else {
                        self.ensureReconnectLoop(name: name)
                    }
                } else {
                    PitBossLog.write(
                        "[app] not reconnecting — wantConnected=\(self.wantConnected) "
                        + "name=\(self.connectedName ?? "nil")")
                    self.phase = .idle
                }
            }
        }
        transport.onLinkRestored = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                PitBossLog.write("[app] link restored by the system — resuming")
                // The foreground ladder, if one was running, has been beaten to
                // it. Stop it rather than let it connect over the top.
                self.reconnectTask?.cancel()
                self.reconnectTask = nil
                await self.resumeAfterRestore()
            }
        }
        transport.onLog = { message in
            // Routed to the host app's unified log.
            PitBossLog.write(message)
        }
    }

    // MARK: - Discovery & connection

    public func scan(seconds: TimeInterval = 8) async {
        phase = .scanning
        do {
            discovered = try await transport.scan(prefix: "PB", seconds: seconds)
            phase = discovered.isEmpty ? .failed("No grills found. Is the grill powered on?") : .idle
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Connects and starts the state poll.
    ///
    /// Takes only the advertised name. The control board is read from that name
    /// (`PBL-<MAC>` → `PBL`) and fully determines decoding and commands, so
    /// there is nothing for the user to choose. The chassis model is not
    /// reported by the firmware and is not needed (ADR 0003 / 0006).
    public func connect(name: String) async {
        wantConnected = true
        connectedName = name
        if await attemptConnect(name: name) { return }
        // The transport arms a system-held connect when the grill isn't
        // advertising. That already recovers the link — and does it with the
        // app suspended, which the ladder cannot — so don't run both.
        if transport.hasStandingReconnect {
            PitBossLog.write("[app] standing connect armed — waiting rather than retrying")
            phase = .awaitingReconnect
            return
        }
        // Don't surface a hard failure: the grill may simply be out of range or
        // still warming up. Keep trying in the background; the phase drives the UI.
        ensureReconnectLoop(name: name)
    }

    /// One discovery + connect attempt. Never throws — it reports through `phase`.
    @discardableResult
    private func attemptConnect(name: String) async -> Bool {
        // A weak link can take well over a minute to establish. Record when we
        // started so the UI can count up rather than sit on a bare "Connecting"
        // that is indistinguishable from a hang.
        connectingSince = Date()
        defer { connectingSince = nil }
        phase = .connecting
        guard let boardName = GrillCatalog.board(fromAdvertisedName: name) else {
            phase = .failed("Couldn't tell which control board '\(name)' uses.")
            PitBossLog.write("[app] no board prefix in advertised name '\(name)'")
            return false
        }
        guard let resolved = catalog.profile(forBoard: boardName) else {
            phase = .failed("'\(boardName)' isn't a control board this app knows.")
            PitBossLog.write("[app] unknown control board '\(boardName)'")
            return false
        }

        profile = resolved
        board = resolved.controlBoard
        PitBossLog.write("[app] detected \(resolved.board) board — \(resolved.minTemp)–\(resolved.maxTemp)°, \(resolved.modelCount) matching models")

        do {
            try await transport.connect(name: name)
            connectedName = name
            // A cook interrupted by the app dying is still the same cook.
            resumeCookIfAny()
            restoreMethodIfAny()
            if cookStore.activeCookID != nil {
                record(CookEvent(at: Date(), kind: .linkRestored))
            }
            // Ask now rather than at launch: the prompt arrives with context.
            await GrillNotifier.shared.requestAuthorization()
            ladderObservations = LadderMemory.load(grill: name)
            chosenLadder = UserDefaults.standard.array(forKey: "ladder.chosen.\(name)") as? [Int]
            if let summary = ladderSummary { PitBossLog.write("[ladder] \(summary)") }
            phase = .connected
            // Ask the board to push updates rather than polling it hard.
            _ = try? await transport.send(method: "PB.SetMCU_UpdateFrequency", params: ["frequency": 2])
            await refresh()
            startPolling()
            return true
        } catch {
            PitBossLog.write("[app] connect attempt failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Recycles a connect that has been pending too long.
    ///
    /// Call when the app returns to the foreground. While suspended the app
    /// cannot run its own timeout, so a connect issued before a long background
    /// stretch can still be sitting there when the cook next looks at the phone
    /// — pending against a grill that may have moved out of range hours ago.
    /// The wall clock is the only honest measure of that, since no timer of
    /// ours was running to notice.
    public func recycleStaleConnect() async {
        guard let since = connectingSince, let name = connectedName, wantConnected else { return }
        let pendingFor = Date().timeIntervalSince(since)
        guard pendingFor > BLETransport.connectTimeout else { return }
        PitBossLog.write("[app] connect has been pending \(Int(pendingFor))s — starting it over")
        transport.stopAutoReconnect()
        connectingSince = nil
        await connect(name: name)
    }

    /// Brings the app back up on a link the *system* reconnected.
    ///
    /// Same tail as a manual connect: re-join the cook, note the gap, re-arm the
    /// push frequency and start polling. Split out rather than duplicated so a
    /// system reconnect and a hand-rolled one cannot drift apart.
    private func resumeAfterRestore() async {
        resumeCookIfAny()
        restoreMethodIfAny()
        if cookStore.activeCookID != nil {
            record(CookEvent(at: Date(), kind: .linkRestored))
        }
        phase = .connected
        _ = try? await transport.send(method: "PB.SetMCU_UpdateFrequency", params: ["frequency": 2])
        await refresh()
        startPolling()
    }

    /// Starts the retry loop, unless one is already running.
    ///
    /// The task inherits this class's `@MainActor` context, so state is touched
    /// directly — only the sleep actually suspends.
    private func ensureReconnectLoop(name: String) {
        guard wantConnected else {
            PitBossLog.write("[app] reconnect loop not started — the user disconnected")
            return
        }
        guard reconnectTask == nil else {
            PitBossLog.write("[app] reconnect loop already running")
            return
        }

        reconnectTask = Task { [weak self] in
            let policy = ReconnectPolicy.standard
            var attempt = 1

            while !Task.isCancelled {
                guard let self, self.wantConnected, !self.isConnected else { break }

                let delay = policy.delay(forAttempt: attempt)
                self.phase = .reconnecting(attempt: attempt, seconds: delay)
                PitBossLog.write("[app] retrying connection in \(delay)s (attempt \(attempt))")

                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                if Task.isCancelled || !self.wantConnected { break }

                // `Task.cancel()` does not interrupt an await already in
                // flight, so a connect started before the cancel can still
                // return success afterwards — against a link that has since
                // dropped again. Re-check before believing it.
                let ok = await self.attemptConnect(name: name)
                if Task.isCancelled { break }
                if !ok, self.transport.hasStandingReconnect {
                    PitBossLog.write("[app] standing connect armed — ladder standing down")
                    self.phase = .awaitingReconnect
                    break
                }
                if ok {
                    PitBossLog.write("[app] reconnected after \(attempt) attempt(s)")
                    break
                }
                attempt += 1
            }
            self?.reconnectTask = nil
        }
    }

    /// Connection state for the UI, which shouldn't have to pattern-match
    /// `phase` in three places.
    public var isConnectedForUI: Bool { isConnected }

    private var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }

    /// Stops trying, for good, until the next explicit connect.
    /// Plays a recorded cook through the UI with no grill attached.
    ///
    /// Used for inspecting and capturing the interface. It drives the same
    /// state path a live grill does — `ingest`-equivalent merging, history
    /// recording, alerts — so what is on screen is produced the normal way.
    public func startReplay(_ source: ReplaySource, board: String = "PBL") {
        profile = catalog.profile(forBoard: board)
        self.board = profile?.controlBoard
        phase = .connected
        PitBossLog.write("[replay] starting — \(source.samples.count) samples")

        Task { [weak self] in
            for index in source.samples.indices {
                guard let self, !Task.isCancelled else { return }
                let next = source.state(at: index)
                let previous = self.state
                self.state = self.state.merged(with: next, reportedKeys: Self.replayKeys)
                self.noteLivingProbes(self.state)
                if self.history.record(self.state, now: source.samples[index].at) {
                    self.samples = self.history.samples
                }
                self.evaluateAlerts(previous: previous, current: self.state)
                // Interval between recorded points, compressed by the rate.
                if index + 1 < source.samples.count {
                    let gap = source.samples[index + 1].at
                        .timeIntervalSince(source.samples[index].at) / source.rate
                    try? await Task.sleep(nanoseconds: UInt64(max(0.01, gap) * 1_000_000_000))
                }
            }
            PitBossLog.write("[replay] finished")
        }
    }

    /// Every field a replayed sample speaks to.
    private static let replayKeys: Set<String> = [
        "moduleIsOn", "grillTemp", "grillSetTemp",
        "p1Temp", "p2Temp", "p3Temp", "p4Temp",
        "motorState", "fanState", "hotState", "isFahrenheit",
    ]

    public func disconnect() {
        wantConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        pollTask?.cancel()
        pollTask = nil
        transport.disconnect()
        phase = .idle
        connectedName = nil
        PitBossLog.write("[app] disconnected by request")
    }

    /// The board pushes frames on the debug channel, but a periodic explicit
    /// read keeps the UI honest if a push is missed.
    private func startPolling(every seconds: TimeInterval = 5) {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                // Stop when there is nothing to poll. Without this a poll loop
                // that outlived its link logged "PB.GetState failed: Not
                // connected" every five seconds forever, draining the battery
                // and burying the real events in the log.
                guard self.transport.isConnected else {
                    PitBossLog.write("[app] poll stopped — the link is down")
                    self.pollTask = nil
                    return
                }
                await self.refresh()
            }
        }
    }

    // MARK: - Commands

    public func setTemperature(_ value: Int) async throws {
        // Choosing a temperature during a cool-down is the cook saying "keep
        // cooking", so it cancels the shutdown rather than fighting it. Guarded
        // on the value so the machine's own ramp-down doesn't cancel itself.
        if shutdownPhase == .cooling, value != shutdownConfig.coolTarget {
            await requestShutdown(.cancel)
        }
        try await send("set-temperature", [value])
        // Watch what the grill does with it — that is how the exact ladder gets
        // learned without asking the cook to identify the model.
        pendingSetpoint = (value, Date())
    }

    public func setLight(_ on: Bool) async throws {
        try await send(on ? "turn-light-on" : "turn-light-off")
    }

    /// Raw primer-motor control. Prefer `primeBurst()` — leaving the primer
    /// running is how pellets end up dumped into the firepot.
    public func setPrime(_ on: Bool) async throws {
        try await send(on ? "turn-primer-motor-on" : "turn-primer-motor-off")
    }

    /// Seconds the primer runs for one burst, matching the desktop.
    public static let primeSeconds = 5

    /// Runs the primer for a fixed burst, then stops it.
    ///
    /// Priming is **momentary**, not a toggle: the desktop sends on, waits, and
    /// sends off. Exposing it as a toggle — as this app first did — means a
    /// missed second tap leaves the auger feeding indefinitely.
    ///
    /// The off command is sent even if the wait is cancelled or the on command's
    /// effects are unclear, because the failure that matters is the motor being
    /// left running.
    public func primeBurst() async {
        guard !isPriming else { return }
        isPriming = true
        primeRemaining = Self.primeSeconds
        PitBossLog.write("[prime] burst starting (\(Self.primeSeconds)s)")

        defer {
            isPriming = false
            primeRemaining = 0
        }

        do {
            try await send("turn-primer-motor-on")
        } catch {
            PitBossLog.write("[prime] failed to start: \(error.localizedDescription)")
            return
        }

        for remaining in stride(from: Self.primeSeconds, through: 1, by: -1) {
            primeRemaining = remaining
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        do {
            try await send("turn-primer-motor-off")
            PitBossLog.write("[prime] burst complete")
        } catch {
            // The motor may still be running: say so loudly rather than quietly.
            PitBossLog.write("[prime] FAILED TO STOP: \(error.localizedDescription)")
            raise(.primeStopFailed)
        }
    }

    /// True while a prime burst is running.
    @Published public private(set) var isPriming = false
    /// Seconds left in the burst, for the countdown.
    @Published public private(set) var primeRemaining = 0

    /// Priming a lit grill is usually a no-op — most boards only run the primer
    /// from idle — so the UI warns instead of silently doing nothing.
    public var primingWouldBeUnusual: Bool { state.moduleIsOn == true }

    /// Raw power-off. Prefer `requestShutdown(.auto)` — cutting power to a hot
    /// grill is the exact thing this project exists because of.
    public func turnOff() async throws {
        try await send("turn-off")
    }

    // MARK: - Graceful shutdown

    /// Starts, escalates, or cancels a graceful shutdown.
    ///
    /// Mirrors the desktop's `requestShutdown`: `.auto` cools first if the grill
    /// is hot, a second press (`.now`) skips the cool-down, and `.cancel` aborts.
    public func requestShutdown(_ mode: ShutdownMode) async {
        switch mode {
        case .cancel:
            guard shutdownPhase != nil else { return }
            endShutdown()
            PitBossLog.write("[shutdown] cancelled — keep cooking")

        case .now:
            endShutdown()
            PitBossLog.write("[shutdown] powering off now (cool-down skipped)")
            try? await send("turn-off")
            raise(.shutdownNotice(title: "Shutting down now",
                                  body: "Turning the grill off."))

        case .auto:
            // A second press while already shutting down means "now".
            if shutdownPhase != nil {
                await requestShutdown(.now)
                return
            }
            let step = Shutdown.begin(ShutdownInput(state: state), config: shutdownConfig)
            shutdownPhase = step.phase
            shutdownStartedAt = Date()
            shutdownStalled = false
            shutdownCoolFrom = state.grillTemp ?? shutdownConfig.coolTarget
            PitBossLog.write("[shutdown] begin — phase \(String(describing: step.phase)) from \(shutdownCoolFrom)°")
            await perform(step)
        }
    }

    /// Advances the machine on each fresh grill state.
    private func driveShutdown() async {
        guard let phase = shutdownPhase else { return }
        let step = Shutdown.advance(phase, ShutdownInput(state: state), config: shutdownConfig)
        await perform(step)

        if step.phase != phase {
            PitBossLog.write("[shutdown] \(String(describing: phase)) → \(String(describing: step.phase))")
        }
        shutdownPhase = step.phase
        if step.phase == nil {
            shutdownStartedAt = nil
            PitBossLog.write("[shutdown] complete — module off and fan stopped")
        }

        // Watchdog: say something rather than cooling forever in silence.
        if shutdownPhase != nil, !shutdownStalled,
           let started = shutdownStartedAt,
           Date().timeIntervalSince(started) > shutdownConfig.stallSeconds {
            shutdownStalled = true
            raise(.shutdownNotice(title: "Shutdown taking a while",
                                  body: "The cool-down hasn't finished — check the grill."))
        }
    }

    private func perform(_ step: ShutdownStep) async {
        switch step.action {
        case .cool:
            try? await setTemperature(shutdownConfig.coolTarget)
        case .off:
            try? await send("turn-off")
        case nil:
            break
        }
        if let notice = step.notice {
            raise(.shutdownNotice(title: notice.title, body: notice.body))
        }
    }

    private func endShutdown() {
        shutdownPhase = nil
        shutdownStartedAt = nil
        shutdownStalled = false
    }

    /// Pulls status + temperatures explicitly.
    ///
    /// Uses `PB.GetState`, which returns both frames **in the RPC reply**
    /// (`sc_11` status, `sc_12` temperatures) rather than asking the board to
    /// push them on the debug channel. That matters: a pushed frame that never
    /// arrives leaves the UI blank with nothing to show for it, whereas this
    /// either returns data or raises an error we can log.
    public func refresh() async {
        guard let board else { return }
        do {
            let params = try await authenticatedParams()
            let result = try await transport.send(method: "PB.GetState", params: params)
            guard let dict = result as? [String: Any] else {
                PitBossLog.write("[rpc] PB.GetState returned no object")
                return
            }

            var merged = state
            var got: [String] = []
            if let frame = dict["sc_11"] as? String,
               let parsed = try board.parseStatus(frame) {
                merged = merged.merged(with: parsed.state, reportedKeys: parsed.reportedKeys)
                got.append("status")
            }
            if let frame = dict["sc_12"] as? String,
               let parsed = try board.parseTemperatures(frame) {
                merged = merged.merged(with: parsed.state, reportedKeys: parsed.reportedKeys)
                got.append("temps")
            }

            noteLivingProbes(merged)
            if got.isEmpty {
                PitBossLog.write("[rpc] PB.GetState had no usable frames — keys: \(dict.keys.sorted())")
            } else {
                let previous = state
                state = merged
                recordHistory(merged)
                advancePellets(merged)
                advanceMaintenance(merged)
                advanceThermal(merged)
                noteSetpoint(merged.grillSetTemp)
                await driveShutdown()
                // Every decoded temperature, not just the headline one.
                // The FE0C frame carries both `grillTemp` (index 23) and
                // `smokerActTemp` (index 17); if a grill's reading looks wrong,
                // the first question is which of those the controller means,
                // and that cannot be answered without seeing both.
                PitBossLog.write("[state] \(got.joined(separator: "+")) — grill \(merged.grillTemp.map(String.init) ?? "—")° set \(merged.grillSetTemp.map(String.init) ?? "—")° smoker \(merged.smokerActTemp.map(String.init) ?? "—")° p1 \(merged.p1Temp.map(String.init) ?? "—")° p2 \(merged.p2Temp.map(String.init) ?? "—")° p3 \(merged.p3Temp.map(String.init) ?? "—")° p4 \(merged.p4Temp.map(String.init) ?? "—")° on=\(merged.moduleIsOn == true) °F=\(merged.isFahrenheit == true)")
                if let raw = dict["sc_12"] as? String {
                    // The undecoded frame, so a suspect reading can be checked
                    // against the bytes rather than against our parsing of them.
                    PitBossLog.write("[frame] sc_12 \(raw)")
                }
                evaluateAlerts(previous: previous, current: merged)
            }
        } catch {
            PitBossLog.write("[rpc] PB.GetState failed: \(error.localizedDescription)")
        }
    }

    /// Params with the grill password attached when one is set.
    private func authenticatedParams(_ base: [String: Any] = [:]) async throws -> [String: Any] {
        guard !password.isEmpty else { return base }
        var params = base
        // The board derives the same key from its own uptime, so this has to be
        // built from a *fresh* reading, not a cached one.
        let uptime = try await currentUptime()
        params["psw"] = Codec.encode(Array(password.utf8),
                                     key: Codec.timedKey(uptime: uptime)).hexString
        return params
    }

    private func send(_ slug: String, _ args: [Int] = []) async throws {
        guard let board else { throw TransportError.notConnected }
        let hex = try board.command(slug, args)
        let params = try await authenticatedParams(["command": hex])
        do {
            try await transport.send(method: "PB.SendMCUCommand", params: params)
            PitBossLog.write("[cmd] \(slug)\(args.isEmpty ? "" : " \(args)") → \(hex) ok")
        } catch {
            // Silently-failing controls are the worst kind: the grill looks
            // unresponsive and there is nothing to go on.
            PitBossLog.write("[cmd] \(slug)\(args.isEmpty ? "" : " \(args)") → \(hex) FAILED: \(error.localizedDescription)")
            throw error
        }
    }

    private func currentUptime() async throws -> Double {
        let result = try await transport.send(method: "PB.GetTime", params: [:])
        guard let dict = result as? [String: Any],
              let time = dict["time"] as? Double ?? (dict["time"] as? NSNumber)?.doubleValue else {
            throw TransportError.badResponse("PB.GetTime did not return a time")
        }
        return time
    }

    // MARK: - Incoming frames

    private func ingest(_ frame: DebugFrame) {
        guard let board else { return }
        let parsed: ParsedFrame?
        switch frame.kind {
        case .status:       parsed = try? board.parseStatus(frame.payload)
        case .temperatures: parsed = try? board.parseTemperatures(frame.payload)
        case .virtualData:  return
        }
        guard let parsed else {
            PitBossLog.write("[frame] \(frame.kind) rejected by the \(board.name) routine")
            return
        }

        let previous = state
        state = state.merged(with: parsed.state, reportedKeys: parsed.reportedKeys)
        noteLivingProbes(state)
        recordHistory(state)
        advancePellets(state)
        advanceMaintenance(state)
        advanceThermal(state)
        noteSetpoint(state.grillSetTemp)
        evaluateAlerts(previous: previous, current: state)
        Task { await driveShutdown() }
    }

    /// A probe that has ever reported a reading is fitted. An unplugged probe
    /// decodes to nil, so this is real detection, not a guess from a model name.
    private func noteLivingProbes(_ s: GrillState) {
        var found = livingProbes
        if s.p1Temp != nil { found.insert(1) }
        if s.p2Temp != nil { found.insert(2) }
        if s.p3Temp != nil { found.insert(3) }
        if s.p4Temp != nil { found.insert(4) }
        if found != livingProbes { livingProbes = found }
    }

    // MARK: - Alerts

    /// Raises the same three alerts the desktop app treats as important:
    /// a probe reaching its target, running out of pellets, and a board error.
    /// Each fires on the *transition* so a standing condition doesn't re-alert.
    private func evaluateAlerts(previous: GrillState, current: GrillState) {
        if current.noPellets == true, previous.noPellets != true {
            raise(.outOfPellets)
            record(CookEvent(at: Date(), kind: .outOfPellets))
        }
        if current.highTempErr == true, previous.highTempErr != true {
            raise(.overTemperature)
        }
        for (flag, previousFlag, label) in [
            (current.fanErr, previous.fanErr, "fan"),
            (current.hotErr, previous.hotErr, "igniter"),
            (current.motorErr, previous.motorErr, "auger"),
            (current.erL, previous.erL, "start-up cycle"),
        ] where flag == true && previousFlag != true {
            raise(.componentError(label))
        }
        // Every probe, against the app-side targets, with hysteresis and an
        // over-target escalation (ProbeAlerting).
        for event in ProbeAlerting.evaluate(state: current, targets: probeTargets, latches: &probeLatches) {
            switch event {
            case .reachedTarget(let probe, let temperature, let target):
                raise(.probeReachedTarget(probe: probe, name: probeTargets.label(for: probe),
                                          temperature: temperature, target: target))
            case .overTarget(let probe, let temperature, let target):
                raise(.probeOverTarget(probe: probe, name: probeTargets.label(for: probe),
                                       temperature: temperature, target: target))
            }
        }
    }

    private func raise(_ kind: GrillAlert.Kind) {
        let alert = GrillAlert(kind: kind, at: Date())
        alerts.append(alert)
        PitBossLog.write("[alert] \(kind.message)")
        // Also to the lock screen when the app isn't on screen — walking away
        // from the grill is the entire point.
        GrillNotifier.shared.post(alert)
    }

    public func clearAlerts() { alerts.removeAll() }
}

/// Something the cook needs to know about.
public struct GrillAlert: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case probeReachedTarget(probe: Int, name: String, temperature: Int, target: Int)
        case probeOverTarget(probe: Int, name: String, temperature: Int, target: Int)
        case outOfPellets
        case overTemperature
        case componentError(String)
        /// Progress from the graceful-shutdown machine.
        case shutdownNotice(title: String, body: String)
        /// The primer was started but the stop command failed.
        case primeStopFailed
        /// The grill read well above its setpoint — possible grease fire.
        case flareup
        /// Temperature falling fast — the lid is probably open.
        case lidOpen(rate: Int, temperature: Int)
        /// A slow sustained decline — the fire is starving.
        case starvingFire(temperature: Int, setTemp: Int)

        public var message: String {
            switch self {
            case .probeReachedTarget(_, let name, let t, let target):
                return "\(name) reached target — \(t)° (target \(target)°)."
            case .probeOverTarget(_, let name, let t, let target):
                return "\(name) is \(t - target)° over target — \(t)°."
            case .outOfPellets:                     return "The hopper is out of pellets."
            case .overTemperature:                  return "The grill is over temperature."
            case .componentError(let what):         return "The \(what) reported an error."
            case .shutdownNotice(_, let body):      return body
            case .lidOpen(let rate, let temperature):
                return "Lid open? Temperature is falling \(abs(rate))°/min, now \(temperature)°."
            case .starvingFire(let temperature, let setTemp):
                return "Running low on pellets? \(temperature)° against a \(setTemp)° setpoint, still falling — check the hopper and firepot."
            case .flareup:
                return "Flare-up — the grill is well above its setpoint. Check for a grease fire."
            case .primeStopFailed:
                return "Couldn't stop the primer — check the grill, the auger may still be feeding."
            }
        }
    }

    public let id = UUID()
    public let kind: Kind
    public let at: Date
}

extension Array where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
