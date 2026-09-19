import SwiftUI
import PitBossKit

/// Sets the grill's target temperature.
///
/// A sheet rather than an always-on panel: the preset ladder and commit button
/// were the tallest block on the dashboard, and the setpoint is something you
/// change occasionally and then watch. The tile shows it; this sets it.
///
/// **Only the firmware's own setpoints are offered — there is deliberately no
/// free stepper.** The controller has a fixed ladder (the PBL one skips 275,
/// documented in docs/test-plan.md E1), the desktop app has only ever sent
/// values from that ladder, and nothing establishes what the board does with a
/// value it doesn't have. Offering a free numeric control would be inventing a
/// capability nobody has verified.
struct GrillTargetView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: GrillController

    var onError: (String) -> Void

    @State private var target: Int = 225
    @State private var showLadderChooser = false

    private var profile: BoardProfile? { controller.profile }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if profile != nil {
                        // Current state, read-only: the setpoint is chosen from
                        // the ladder below, not dialled.
                        VStack(spacing: 2) {
                            Text("\(target)°")
                                .font(.system(size: 44, weight: .semibold, design: .rounded))
                                .foregroundStyle(theme.flame)
                                .contentTransition(.numericText())
                            Text(subtitle ?? "")
                                .font(.caption)
                                .foregroundStyle(theme.textMuted)
                        }
                        .frame(maxWidth: .infinity)

                        let presets = controller.presets
                        if !presets.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 8)], spacing: 8) {
                                ForEach(presets, id: \.self) { temp in
                                    Button("\(temp)°") { target = temp }
                                        .buttonStyle(GrillButtonStyle(
                                            tint: target == temp ? theme.flame : nil,
                                            prominent: target == temp))
                                }
                            }
                        }

                        Button(target == controller.state.grillSetTemp
                               ? "Already set to \(target)°"
                               : "Set grill to \(target)°") {
                            commit()
                        }
                        .buttonStyle(GrillButtonStyle(tint: theme.flame,
                                                      prominent: target != controller.state.grillSetTemp))
                        .disabled(target == controller.state.grillSetTemp)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("The controller only accepts its own ladder, so there's no free-entry dial.")
                                .font(.caption)
                                .foregroundStyle(theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)

                            if let summary = controller.ladderSummary {
                                Label(summary, systemImage: "checkmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(theme.green)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            // The exact ladder varies by chassis and the firmware
                            // reports no model (ADR 0003), so offer the correction
                            // as a choice between actual value lists — nobody
                            // should have to know their model number.
                            if controller.ladderOptions.count > 1 {
                                Button {
                                    showLadderChooser = true
                                } label: {
                                    Label("My grill has different steps",
                                          systemImage: "slider.horizontal.3")
                                        .font(.caption)
                                }
                            }
                        }
                    } else {
                        Text("Not connected to a grill.")
                            .foregroundStyle(theme.textMuted)
                    }
                }
                .padding()
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background)
            .navigationTitle("Grill temperature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
        .task {
            target = controller.state.grillSetTemp ?? profile?.minTemp ?? 225
        }
        .sheet(isPresented: $showLadderChooser) {
            LadderChooser(controller: controller)
        }
    }

    private var subtitle: String? {
        guard let profile else { return nil }
        if let now = controller.state.grillTemp {
            return "now \(now)° · range \(profile.minTemp)–\(profile.maxTemp)°"
        }
        return "range \(profile.minTemp)–\(profile.maxTemp)°"
    }

    private func commit() {
        Task {
            do { try await controller.setTemperature(target) }
            catch { onError(error.localizedDescription) }
        }
        dismiss()
    }
}
