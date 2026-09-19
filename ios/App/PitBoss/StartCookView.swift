import SwiftUI
import PitBossKit

/// Sets up a whole cook in one action: pick a cut, and the grill temperature
/// and probe target are both set, with the probe named after the cut.
///
/// The catalogue knows both halves — a brisket wants 250° in the chamber and
/// 203° in the meat — so making the cook set them separately was busywork.
///
/// It shows exactly what it will do before doing it, including when the cut's
/// recommendation has to be snapped onto a setpoint this grill actually has.
struct StartCookView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: GrillController

    var onError: (String) -> Void

    @State private var query = ""
    @State private var plan: GrillController.PlannedCook?
    @State private var probe = 1
    @State private var method: CookMethod?

    private var results: [MeatCut] {
        MeatCatalog.search(query).filter { $0.grillTemp != nil }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let plan { confirmation(plan) }
                else { cutList }
            }
            .background(theme.background)
            .navigationTitle(plan == nil ? "Start a cook" : plan!.cut.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if plan != nil {
                        Button("Back") { withAnimation { plan = nil } }
                    } else {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
    }

    private var cutList: some View {
        List {
            ForEach(MeatCategory.allCases) { category in
                let cuts = results.filter { $0.category == category }
                if !cuts.isEmpty {
                    Section(category.label) {
                        ForEach(cuts) { cut in
                            Button {
                                guard let target = cut.suggested else { return }
                                withAnimation {
                                    plan = controller.planCook(cut: cut, target: target, probe: probe)
                                }
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cut.name)
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(theme.text)
                                        if let grill = cut.grillTemp, let target = cut.suggested {
                                            Text("grill \(grill)° · probe \(target.temperature)°")
                                                .font(.caption)
                                                .foregroundStyle(theme.textMuted)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(theme.textMuted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Brisket, pork butt, wings…")
        .sheet(item: $method) { m in
            MethodView(method: m,
                       onUse: { setpoint in
                           Task { try? await controller.setTemperature(setpoint) }
                       },
                       availableSetpoints: controller.presets,
                       onStart: { controller.startMethod(m, cut: plan?.cut) })
        }
        .task {
            // Capture hook for the screenshot harness, same family as
            // PITBOSS_OPEN: preselects a cut so the confirmation step can be
            // captured without driving a tap.
            guard let wanted = ProcessInfo.processInfo.environment["PITBOSS_COOK"],
                  let cut = MeatCatalog.presetable.first(where: {
                      $0.name.localizedCaseInsensitiveContains(wanted) }),
                  let target = cut.suggested else { return }
            plan = controller.planCook(cut: cut, target: target, probe: probe)
        }
    }

    private func confirmation(_ plan: GrillController.PlannedCook) -> some View {
        FillingScrollView(spacing: 16, readingWidth: 620) {
            VStack(alignment: .leading, spacing: 16) {
                // What will happen, in the grill's own numbers.
                VStack(spacing: 12) {
                    row("Grill", plan.grillSetpoint.map { "\($0)°" } ?? "unchanged", theme.flame)
                    Divider().overlay(theme.border)
                    row("Probe \(plan.probe)", "\(plan.target.temperature)° · \(plan.target.label)",
                        theme.green)
                    Divider().overlay(theme.border)
                    row("Probe name", plan.cut.name, theme.accent)
                }
                .padding(14)
                .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))

                if plan.grillWasAdjusted, let wanted = plan.recommendedGrill,
                   let actual = plan.grillSetpoint {
                    // Don't silently substitute a different temperature.
                    NoticeBanner(
                        text: "\(plan.cut.name) is usually cooked at \(wanted)°, which isn't on this grill's ladder — using \(actual)° instead.",
                        tint: theme.amber)
                }

                if MeatCatalog.isBelowSafeMinimum(plan.target, for: plan.cut),
                   let floor = plan.cut.safeFloor {
                    NoticeBanner(
                        text: "\(plan.target.temperature)° is below the \(floor)° USDA safe minimum for \(plan.cut.category.label.lowercased()).",
                        tint: theme.amber)
                }

                if !plan.cut.methods.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("METHODS")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.textMuted)
                        ForEach(plan.cut.methods) { m in
                            Button { method = m } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "list.number").foregroundStyle(theme.flame)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(m.name).font(.subheadline.weight(.semibold))
                                                .foregroundStyle(theme.text)
                                            if let duration = m.durationLabel {
                                                Text(duration).font(.caption2)
                                                    .foregroundStyle(theme.textMuted)
                                            }
                                        }
                                        Text(m.summary)
                                            .font(.caption)
                                            .foregroundStyle(theme.textMuted)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2).foregroundStyle(theme.textMuted)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let note = plan.cut.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if plan.cut.targets.count > 1 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("OR AIM FOR")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.textMuted)
                        ForEach(plan.cut.targets.filter { $0 != plan.target }) { alternative in
                            Button {
                                self.plan = controller.planCook(cut: plan.cut,
                                                                target: alternative,
                                                                probe: plan.probe)
                            } label: {
                                HStack {
                                    Text("\(alternative.temperature)°")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                    Text(alternative.label).font(.subheadline)
                                    Spacer(minLength: 0)
                                }
                            }
                            .buttonStyle(GrillButtonStyle())
                        }
                    }
                }

                probePicker(plan)

                Spacer(minLength: 12)

                Button("Start the cook") { start(plan) }
                    .buttonStyle(GrillButtonStyle(tint: theme.flame, prominent: true))
                    .disabled(!controller.isConnectedForUI)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Probes worth offering.
    ///
    /// `maxProbes` is the most any grill *on this board* has — four, for PBL —
    /// which is wrong for a two-probe grill in exactly the way the setpoint
    /// ladder was. Prefer probes this grill has actually reported, and fall
    /// back to the board maximum only before anything has been seen.
    private var selectableProbes: [Int] {
        let seen = Set(controller.livingProbes)
            .union(controller.probeTargets.targets.filter { $0.value > 0 }.keys)
        if !seen.isEmpty { return seen.sorted() }
        return Array(1...(controller.profile?.maxProbes ?? 1))
    }

    @ViewBuilder
    private func probePicker(_ plan: GrillController.PlannedCook) -> some View {
        let probes = selectableProbes
        if probes.count > 1 {
            VStack(alignment: .leading, spacing: 8) {
                Text("USE PROBE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.textMuted)
                Picker("Probe", selection: $probe) {
                    ForEach(probes, id: \.self) { n in
                        Text("Probe \(n)").tag(n)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: probe) { _, n in
                    self.plan = controller.planCook(cut: plan.cut, target: plan.target, probe: n)
                }
            }
        }
    }

    private func row(_ label: String, _ value: String, _ tint: Color) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(theme.textMuted)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.trailing)
        }
    }

    private func start(_ plan: GrillController.PlannedCook) {
        Task {
            do {
                try await controller.startCook(plan)
                dismiss()
            } catch {
                onError(error.localizedDescription)
            }
        }
    }
}
