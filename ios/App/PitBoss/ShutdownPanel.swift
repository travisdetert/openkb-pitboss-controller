import SwiftUI
import PitBossKit

/// The graceful-shutdown control.
///
/// Turning a hot pellet grill straight off can let fire smoulder back up the
/// auger toward the hopper. On this grill that burnback melted a bushing and
/// seized the auger motor — which is why the safe path is the default here and
/// the immediate power-off takes a deliberate second press.
struct ShutdownPanel: View {
    @Environment(\.theme) private var theme
    @ObservedObject var controller: GrillController

    var onError: (String) -> Void

    @State private var confirmSkip = false

    private var state: GrillState { controller.state }

    var body: some View {
        content
            // Skipping the cool-down is the exact action that caused the
            // burnback this project exists because of — it gets a confirm.
            .confirmationDialog("Skip the cool-down and shut off now?",
                                isPresented: $confirmSkip, titleVisibility: .visible) {
                Button("Power off now", role: .destructive) {
                    Task { await controller.requestShutdown(.now) }
                }
                Button("Keep cooling", role: .cancel) {}
            } message: {
                Text("Cutting power while the grill is hot can let fire creep back up the auger toward the hopper.")
            }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch controller.shutdownPhase {
            case .none:
                Button("Turn grill off") {
                    Task { await controller.requestShutdown(.auto) }
                }
                .buttonStyle(GrillButtonStyle(tint: theme.red))

            case .cooling:
                cooling

            case .finishing:
                finishing
            }
        }
    }

    private var cooling: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "thermometer.medium.slash")
                    .foregroundStyle(theme.amber)
                Text("Cooling before shutdown")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.text)
            }

            // Say the actual numbers: a bare progress bar during a safety step
            // is not reassuring, it is just a bar.
            Text("Holding at 200° until the grill is cool enough to power off safely. Now \(state.grillTemp.map(String.init) ?? "—")°, from \(controller.shutdownCoolFrom)°.")
                .font(.footnote)
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if let progress = controller.coolProgress {
                ProgressView(value: progress)
                    .tint(theme.flame)
                Text("\(Int(progress * 100))% cooled")
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
            }

            if controller.shutdownStalled {
                NoticeBanner(text: "The cool-down hasn't finished — check the grill.",
                             tint: theme.amber)
            }

            HStack(spacing: 10) {
                Button("Keep cooking") {
                    Task { await controller.requestShutdown(.cancel) }
                }
                .buttonStyle(GrillButtonStyle())

                Button("Power off now") { confirmSkip = true }
                    .buttonStyle(GrillButtonStyle(tint: theme.red))
            }

            Text("Powering off now skips the cool-down. That is the condition that causes hopper burnback.")
                .font(.caption2)
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.amber.opacity(0.5), lineWidth: 1))
    }

    private var finishing: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "fan.fill")
                    .foregroundStyle(state.fanState == true ? theme.accent : theme.inactive)
                    // .rotate needs iOS 18; .pulse is available at our iOS 17 floor.
                    .symbolEffect(.pulse, isActive: state.fanState == true)
                Text("Fan cooling the firepot…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.text)
            }
            Text("The grill is off. Let the fan finish — it's what puts the fire out. This panel clears when the module is off and the fan has stopped.")
                .font(.footnote)
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            if controller.shutdownStalled {
                NoticeBanner(text: "The cool-down hasn't finished — check the grill.",
                             tint: theme.amber)
            }
        }
        .padding(12)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
    }
}
