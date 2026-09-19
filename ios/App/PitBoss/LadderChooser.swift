import SwiftUI
import PitBossKit

/// Picks which setpoint ladder this grill actually has.
///
/// Deliberately not a model picker. The firmware reports no model (ADR 0003),
/// and asking someone to find a part number on a sticker to fix a list of
/// numbers is the wrong question — so this shows the candidate ladders as the
/// values themselves and asks which matches the grill's own display.
///
/// Boards whose models all agree never reach this screen.
struct LadderChooser: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: GrillController

    private var current: [Int] { controller.presets }

    var body: some View {
        NavigationStack {
            FillingScrollView(spacing: 14, readingWidth: 620) {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Which set of temperatures does your grill offer?")
                        .font(.headline)
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Compare with the grill's own display or dial. Picking the wrong one only affects which buttons appear here — it can't harm the grill, and a setpoint it doesn't have simply won't take.")
                        .font(.caption)
                        .foregroundStyle(theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(controller.ladderOptions.enumerated()), id: \.offset) { _, ladder in
                        option(ladder)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background)
            .navigationTitle("Setpoints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func option(_ ladder: [Int]) -> some View {
        let selected = Set(ladder) == Set(current)
        return Button {
            controller.chooseLadder(ladder)
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(ladder.count) steps")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.text)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.green)
                    }
                }
                // The values themselves, wrapped — this is the thing being
                // chosen, so it has to be legible at a glance.
                Text(ladder.map(String.init).joined(separator: "  ·  "))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .stroke(selected ? theme.green : theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}
