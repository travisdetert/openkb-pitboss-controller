import SwiftUI
import PitBossKit

/// The hopper level, as a slim bar under the temperature tiles.
///
/// This is an **estimate from auger run-time**, not a sensor reading — the grill
/// has no pellet sensor. It says "~" everywhere for that reason, and its
/// accuracy depends entirely on the cook tapping Refilled.
struct HopperBar: View {
    @Environment(\.theme) private var theme
    @ObservedObject var controller: GrillController

    private var tint: Color {
        switch controller.pelletLevel {
        case .ok:       return theme.green
        case .low:      return theme.amber
        case .critical: return theme.red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("HOPPER")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(theme.textMuted)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(theme.textMuted)
                Spacer(minLength: 0)
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceRaised)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geo.size.width * controller.pelletPercent / 100))
                }
            }
            .frame(height: 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hopper about \(Int(controller.pelletPercent)) percent")
    }

    private var summary: String {
        var parts = ["~\(Int(controller.pelletPercent.rounded()))%",
                     "~\(String(format: "%.1f", controller.pelletPoundsLeft)) of \(Int(controller.pellets.capacityLbs)) lb"]
        if let hours = controller.pelletHoursLeft {
            parts.append("~\(PelletEstimate.durationLabel(hours)) left")
        }
        return parts.joined(separator: " · ")
    }
}

/// Hopper settings and the two recalibration actions.
struct HopperView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: GrillController

    @State private var capacity: Double = 20
    @State private var feedRate: Double = 8

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    level
                    actions
                    settings
                    caveat
                }
                .padding()
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(theme.background)
            .navigationTitle("Pellet hopper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
            }
        }
        .task {
            capacity = controller.pellets.capacityLbs
            feedRate = controller.pellets.feedRateLbsPerHr
        }
    }

    private var level: some View {
        VStack(spacing: 2) {
            Text("~\(Int(controller.pelletPercent.rounded()))%")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(theme.text)
            Text("~\(String(format: "%.1f", controller.pelletPoundsLeft)) of \(Int(controller.pellets.capacityLbs)) lb remaining")
                .font(.caption)
                .foregroundStyle(theme.textMuted)
            if let hours = controller.pelletHoursLeft {
                Text("~\(PelletEstimate.durationLabel(hours)) at the current burn rate")
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
            }
            if let refilled = controller.pellets.refilledAt {
                Text("Filled \(refilled.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(theme.textMuted)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button("I filled the hopper") { controller.markHopperRefilled() }
                .buttonStyle(GrillButtonStyle(tint: theme.green, prominent: true))
            Button("I emptied the hopper") { controller.markHopperEmptied() }
                .buttonStyle(GrillButtonStyle())
            Text("Emptying the hopper between cooks keeps pellets dry — they swell and jam the auger if they take on moisture.")
                .font(.caption)
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOPPER")
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.textMuted)
            row("Capacity", value: $capacity, unit: "lb", range: 5...60, step: 1)
            row("Feed rate", value: $feedRate, unit: "lb/hr", range: 1...20, step: 0.5)
            Text("Feed rate is pounds burned per hour of **auger run-time**, not per hour of cooking. If the estimate consistently runs low, raise it.")
                .font(.caption)
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, value: Binding<Double>, unit: String,
                     range: ClosedRange<Double>, step: Double) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(theme.text)
            Spacer()
            Stepper(value: value, in: range, step: step) {
                Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                    .font(.subheadline.weight(.medium).monospacedDigit())
                    .foregroundStyle(theme.text)
            }
            .labelsHidden()
            .fixedSize()
            Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(0...1)))) \(unit)")
                .font(.subheadline.weight(.medium).monospacedDigit())
                .foregroundStyle(theme.textMuted)
                .frame(width: 84, alignment: .trailing)
        }
        .onChange(of: value.wrappedValue) { _, _ in
            controller.setHopper(capacityLbs: capacity, feedRateLbsPerHr: feedRate)
        }
    }

    private var caveat: some View {
        // Be explicit that this is inferred. A number that looks like a sensor
        // reading but isn't is worse than no number.
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(theme.accent)
            Text("The grill has no pellet sensor. This is estimated from how long the auger has run since you last said the hopper was full — so it's only as good as that. Tap **I filled the hopper** every time you top it up.")
                .font(.footnote)
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
