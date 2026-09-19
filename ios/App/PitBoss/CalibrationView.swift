import SwiftUI
import PitBossKit

/// Grate-level calibration.
///
/// Framed as "where the food is" rather than as correcting a wrong reading,
/// because the controller is not wrong — its sensor is simply somewhere else.
/// The RTD sits on the barrel wall near the controller; a thermometer at grate
/// level is in a cooler part of the barrel, and a 25–50° gap between them is
/// normal on a pellet grill rather than a sign of a failed sensor.
struct CalibrationView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: GrillController

    @State private var offset = 0

    var body: some View {
        NavigationStack {
            FillingScrollView(spacing: 18, readingWidth: 620) {
                VStack(alignment: .leading, spacing: 18) {
                    explanation
                    control
                    comparison
                    scope
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background)
            .navigationTitle("Grate calibration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                if offset != 0 {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Reset") { offset = 0 }
                    }
                }
            }
        }
        .task { offset = controller.grateOffset }
        .onChange(of: offset) { _, new in controller.setGrateOffset(new) }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("The controller's sensor sits on the barrel wall, not at the grate.")
                .font(.headline)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("A thermometer on the grate usually reads lower. A 25–50° difference is normal and does not mean anything is broken. Set the difference here and the dashboard shows both.")
                .font(.subheadline)
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var control: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("GRATE READS")
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.textMuted)
            TargetStepper(value: $offset, range: -100...100, step: 5,
                          subtitle: offset == 0
                              ? "the same as the controller"
                              : "\(abs(offset))° \(offset < 0 ? "cooler" : "hotter") than the controller")
        }
    }

    @ViewBuilder
    private var comparison: some View {
        if let now = controller.state.grillTemp {
            HStack {
                reading("Controller", now, theme.textMuted)
                Image(systemName: "arrow.right").foregroundStyle(theme.textMuted)
                reading("Grate", now + offset, offset == 0 ? theme.textMuted : theme.green)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
        } else {
            Text("Connect to the grill to see the comparison live.")
                .font(.footnote)
                .foregroundStyle(theme.textMuted)
        }
    }

    private func reading(_ label: String, _ value: Int, _ tint: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)°")
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(label).font(.caption2).foregroundStyle(theme.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    private var scope: some View {
        // Say exactly what this does and does not touch. An offset that silently
        // shifted the safety thresholds would be a genuinely dangerous setting.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(theme.accent)
            Text("This only adds a second reading. The setpoint you send, the cool-down shutdown, lid-open and flare-up detection all keep using the controller's own value — and recorded cooks store it unchanged, so an old cook still means what it meant.")
                .font(.footnote)
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
