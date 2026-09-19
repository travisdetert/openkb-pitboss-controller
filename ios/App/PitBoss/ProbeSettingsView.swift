import SwiftUI
import PitBossKit

/// Sets a probe's target temperature and name.
///
/// The target always drives the app's alerting. Whether it also reaches the
/// grill depends on the board — PBL has a probe-1 target command and nothing
/// for probe 2 — so the sheet says which is happening rather than leaving the
/// cook to wonder why the grill's own display disagrees.
struct ProbeSettingsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: GrillController

    let probe: Int
    var onError: (String) -> Void

    @State private var target: Int = 145
    @State private var name: String = ""
    @State private var showCutPicker = false
    /// The cut this target came from, when it came from the catalogue. Held
    /// whole rather than as loose strings so its *own* targets can replace the
    /// generic landmarks — "Poultry 165°" under a brisket is nonsense.
    @State private var chosenCut: MeatCut?
    @State private var chosenTarget: MeatTarget?

    /// Doneness landmarks, so the common case is one tap.
    private var pushesToGrill: Bool { controller.supportsHardwareTarget(probe: probe) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    naming
                    targetControl
                    presetGrid
                    delivery
                }
                .padding()
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background)
            .navigationTitle(controller.probeTargets.label(for: probe))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save() }.fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showCutPicker) {
            CutPickerView { cut, pick in
                target = pick.temperature
                // Name the probe after the cut unless it already has a name —
                // "Brisket · 203°" beats "Probe 1 · 203°" in an alert.
                if name.trimmingCharacters(in: .whitespaces).isEmpty { name = cut.name }
                chosenCut = cut
                chosenTarget = pick
            }
        }
        .task {
            // Capture hook, same family as PITBOSS_OPEN elsewhere.
            if ProcessInfo.processInfo.environment["PITBOSS_OPEN"]?.hasSuffix("cuts") == true {
                showCutPicker = true
            }
            // Capture hook, same family as PITBOSS_OPEN.
            if let wanted = ProcessInfo.processInfo.environment["PITBOSS_PROBE_CUT"],
               let cut = MeatCatalog.cuts.first(where: {
                   $0.name.localizedCaseInsensitiveContains(wanted) }),
               let pick = cut.suggested {
                chosenCut = cut
                chosenTarget = pick
                name = cut.name
                target = pick.temperature
                return
            }
            target = controller.probeTargets.target(for: probe) ?? 145
            name = controller.probeTargets.labels[probe] ?? ""
        }
    }

    private var naming: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("NAME")
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.textMuted)
            TextField("Brisket, chicken, …", text: $name)
                .textFieldStyle(.roundedBorder)
            Text("Named probes are used in alerts, and are saved into each cook.")
                .font(.caption)
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var targetControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TARGET")
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.textMuted)
            TargetStepper(value: $target,
                          range: 32...500,
                          subtitle: currentReading.map { "now \($0)°" })
            Text("Set anything you like — a cut below is just a starting point.")
                .font(.caption2)
                .foregroundStyle(theme.textMuted)
        }
    }

    private var presetGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                showCutPicker = true
            } label: {
                HStack {
                    Image(systemName: "fork.knife")
                    Text(chosenCut == nil ? "Choose a cut" : "Choose a different cut")
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption)
                }
            }
            .buttonStyle(GrillButtonStyle(prominent: chosenCut == nil))

            if let provenance {
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(target == chosenTarget?.temperature ? theme.textMuted : theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let belowFloorNote {
                Text(belowFloorNote)
                    .font(.caption)
                    .foregroundStyle(theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Once a cut is chosen the options are *its* targets. Generic
            // landmarks only make sense before you've said what you're cooking:
            // "Poultry 165°" sitting under a brisket is noise at best.
            if let cut = chosenCut {
                if cut.targets.count > 1 {
                    Text("\(cut.name.uppercased()) TARGETS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(theme.textMuted)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                        ForEach(cut.targets) { option in
                            Button {
                                target = option.temperature
                                chosenTarget = option
                            } label: {
                                VStack(spacing: 1) {
                                    Text("\(option.temperature)°").font(.subheadline.weight(.semibold))
                                    Text(option.label).font(.caption2).lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                            }
                            .buttonStyle(GrillButtonStyle(
                                tint: target == option.temperature ? theme.green : nil,
                                prominent: target == option.temperature))
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)], spacing: 8) {
                    ForEach(quickPresets, id: \.0) { temp, label in
                        Button { target = temp } label: {
                            VStack(spacing: 1) {
                                Text("\(temp)°").font(.subheadline.weight(.semibold))
                                Text(label).font(.caption2)
                            }
                        }
                        .buttonStyle(GrillButtonStyle(
                            tint: target == temp ? theme.green : nil,
                            prominent: target == temp))
                    }
                }
            }
        }
    }

    /// Landmarks for when no cut has been chosen yet. The picker covers
    /// anything specific.
    private let quickPresets: [(Int, String)] = [
        (135, "Med rare"), (145, "Pork / med"), (165, "Poultry"), (203, "Brisket"),
    ]

    /// Says where the number came from, and whether it has since been changed.
    /// The catalogue is a starting point, not a constraint — the stepper always
    /// wins, and saying so beats silently discarding the provenance.
    private var provenance: String? {
        guard let cut = chosenCut, let chosen = chosenTarget else { return nil }
        if target == chosen.temperature { return "\(cut.name) · \(chosen.label)" }
        return "\(cut.name) · \(chosen.label) suggests \(chosen.temperature)° — using your \(target)°"
    }

    /// Checked against the *current* value, not the one originally picked, so
    /// stepping down under the floor still warns.
    private var belowFloorNote: String? {
        guard let cut = chosenCut, let floor = cut.safeFloor, target < floor else { return nil }
        return "\(target)° is below the \(floor)° USDA safe minimum for \(cut.category.label.lowercased())."
    }

    private var delivery: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Say plainly where the target lives. A probe-2 target that the
            // grill never hears about would otherwise look like a bug.
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: pushesToGrill ? "antenna.radiowaves.left.and.right" : "iphone")
                    .foregroundStyle(pushesToGrill ? theme.green : theme.accent)
                Text(pushesToGrill
                     ? "Sent to the grill, and used for alerts here."
                     : "Used for alerts on this phone. This grill's control board (\(controller.profile?.board ?? "—")) has no probe \(probe) target, so the grill itself won't show it.")
                    .font(.footnote)
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if controller.probeTargets.target(for: probe) != nil {
                Button("Clear target") {
                    controller.clearProbeTarget(probe: probe)
                    dismiss()
                }
                .buttonStyle(GrillButtonStyle(tint: theme.red))
            }
        }
    }

    private var currentReading: Int? {
        switch probe {
        case 1: return controller.state.p1Temp
        case 2: return controller.state.p2Temp
        case 3: return controller.state.p3Temp
        default: return controller.state.p4Temp
        }
    }

    private func save() {
        controller.setProbeLabel(probe: probe, name: name)
        Task {
            do { try await controller.setProbeTarget(probe: probe, value: target) }
            catch { onError(error.localizedDescription) }
        }
        dismiss()
    }
}
