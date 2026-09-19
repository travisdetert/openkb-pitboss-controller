import SwiftUI
import PitBossKit

/// The start-of-cook checklist.
///
/// Two things are worth doing before every cook and are easy to skip: clearing
/// the firepot of ash, and topping up the hopper. Both are cheap now and
/// expensive later — a clogged firepot causes the hard starts and flare-ups this
/// app has to detect, and running out of pellets mid-brisket ends the cook.
///
/// It is a checklist, not a gate. Every item can be skipped, and skipping is a
/// plain button rather than a buried one — a prompt that can't be dismissed
/// quickly gets dismissed carelessly.
///
/// Marking an item done is not cosmetic: **Cleaned** resets the maintenance
/// counters and **Filled** resets the pellet estimate, so answering honestly is
/// what keeps both readouts meaningful.
struct PreCookChecklist: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: GrillController

    @State private var firepotDone = false
    @State private var hopperDone = false

    var body: some View {
        NavigationStack {
            FillingScrollView(spacing: 16, readingWidth: 620) {
                VStack(alignment: .leading, spacing: 16) {
                    header

                    item(
                        title: "Clean the firepot",
                        icon: "flame",
                        done: $firepotDone,
                        detail: firepotDetail,
                        urgent: controller.cleaningIsDue,
                        onDone: { controller.markCleaned() })

                    item(
                        title: "Fill the hopper",
                        icon: "tray.and.arrow.down",
                        done: $hopperDone,
                        detail: hopperDetail,
                        urgent: controller.pelletLevel != .ok,
                        onDone: { controller.markHopperRefilled() })

                    Text("Ash in the firepot causes hard starts and flare-ups. A hopper that runs dry mid-cook drops the fire and needs a re-prime.")
                        .font(.caption)
                        .foregroundStyle(theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    // Pushes the action to the bottom of the screen rather than
                    // leaving it stranded under the last card.
                    Spacer(minLength: 12)

                    Button("Start cooking") { dismiss() }
                        .buttonStyle(GrillButtonStyle(tint: theme.flame, prominent: true))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.background)
            .navigationTitle("Before you cook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Skip all") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        Text(controller.cleaningIsDue
             ? "A clean is due before this cook."
             : "Two quick checks before you light it.")
            .font(.headline)
            .foregroundStyle(theme.text)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var firepotDetail: String {
        let reasons = controller.cleaningReasons
        if reasons.isEmpty {
            if let cleaned = controller.maintenance.cleanedAt {
                return "Last cleaned \(cleaned.formatted(date: .abbreviated, time: .omitted)) · \(controller.maintenance.cooksSinceClean) cooks since."
            }
            return "No clean recorded yet."
        }
        return "Due after \(reasons.joined(separator: ", "))."
    }

    private var hopperDetail: String {
        "Estimated ~\(Int(controller.pelletPercent.rounded()))% · ~\(String(format: "%.1f", controller.pelletPoundsLeft)) of \(Int(controller.pellets.capacityLbs)) lb."
    }

    private func item(title: String, icon: String, done: Binding<Bool>,
                      detail: String, urgent: Bool,
                      onDone: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: done.wrappedValue ? "checkmark.circle.fill" : icon)
                    .font(.title3)
                    .foregroundStyle(done.wrappedValue ? theme.green
                                     : (urgent ? theme.amber : theme.textMuted))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.text)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !done.wrappedValue {
                HStack(spacing: 10) {
                    Button("Did it") {
                        onDone()
                        withAnimation { done.wrappedValue = true }
                    }
                    .buttonStyle(GrillButtonStyle(tint: theme.green, prominent: true))

                    Button("Skip") { withAnimation { done.wrappedValue = true } }
                        .buttonStyle(GrillButtonStyle())
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(urgent && !done.wrappedValue ? theme.amber.opacity(0.6) : theme.border,
                        lineWidth: 1))
    }
}
