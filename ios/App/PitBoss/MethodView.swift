import SwiftUI
import PitBossKit

/// A method's stages, laid out in order.
///
/// The temperature tells you when it's done; the method tells you what to do
/// along the way, which is the part people actually look up. 3-2-1 isn't a
/// different target, it's a procedure.
struct MethodView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let method: CookMethod
    /// Applies the method's grill temperature, snapped to this grill's ladder.
    var onUse: ((Int) -> Void)?
    var availableSetpoints: [Int] = []
    /// Makes this the current cook type and schedules its stage reminders.
    var onStart: (() -> Void)?
    /// Non-nil when this method is already running.
    var activeSince: Date?
    var onEnd: (() -> Void)?

    private var snapped: Int? {
        guard let wanted = method.grillTemp else { return nil }
        return MeatCatalog.nearestSetpoint(to: wanted, in: availableSetpoints)
    }

    var body: some View {
        NavigationStack {
            FillingScrollView(spacing: 16, readingWidth: 620) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    ForEach(Array(method.steps.enumerated()), id: \.offset) { index, step in
                        stepCard(index + 1, step, current: currentStepIndex == index)
                    }
                    if let note = method.note {
                        // Where the method's limits live — the honest caveat
                        // that "3-2-1 can overshoot into mushy".
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lightbulb").foregroundStyle(theme.amber)
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 12)

                    if let onUse, let setpoint = snapped {
                        Button("Set the grill to \(setpoint)°") {
                            onUse(setpoint)
                            dismiss()
                        }
                        .buttonStyle(GrillButtonStyle(tint: theme.flame, prominent: true))
                    }

                    if activeSince == nil, let onStart {
                        Button(MethodTimeline.isTimed(method)
                               ? "Start this method — remind me at each stage"
                               : "Make this the current method") {
                            onStart()
                            dismiss()
                        }
                        .buttonStyle(GrillButtonStyle(tint: theme.green, prominent: true))

                        if !MethodTimeline.isTimed(method) {
                            // Don't promise reminders a temperature-driven
                            // method can't produce.
                            Text("This method's stages are driven by temperature, not a clock, so there are no timed reminders — the probe alert is what tells you.")
                                .font(.caption2)
                                .foregroundStyle(theme.textMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let onEnd, activeSince != nil {
                        Button("Stop following this method") {
                            onEnd()
                            dismiss()
                        }
                        .buttonStyle(GrillButtonStyle(tint: theme.red))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background)
            .navigationTitle(method.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(method.summary)
                .font(.headline)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if let duration = method.durationLabel {
                    Label(duration, systemImage: "clock")
                }
                if let grill = method.grillTemp {
                    Label("\(grill)°", systemImage: "flame")
                }
            }
            .font(.caption)
            .foregroundStyle(theme.textMuted)
        }
    }

    /// Which stage is current, when the method is running.
    private var currentStepIndex: Int? {
        guard let since = activeSince else { return nil }
        return MethodTimeline.progress(method, startedAt: since)?.stepIndex
    }

    private func stepCard(_ number: Int, _ step: MethodStep, current: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(theme.background)
                .frame(width: 24, height: 24)
                .background(theme.flame, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(step.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.text)
                    if let minutes = step.minutes, minutes > 0 {
                        Text(minutes >= 60 ? "\(minutes / 60)h" : "\(minutes)m")
                            .font(.caption).foregroundStyle(theme.textMuted)
                    }
                    if let temp = step.grillTemp {
                        Text("\(temp)°").font(.caption).foregroundStyle(theme.flame)
                    }
                }
                Text(step.detail)
                    .font(.footnote)
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14)
            .stroke(current ? theme.flame : theme.border, lineWidth: current ? 2 : 1))
    }
}
