import SwiftUI
import PitBossKit

/// A labelled temperature.
///
/// Sized to sit several-across on a phone: the reading still dominates, but not
/// at a size that forces the row to wrap. Every tile is the same height
/// regardless of whether it has a target line, so a row reads as a row.
struct TemperatureTile: View {
    @Environment(\.theme) private var theme

    let label: String
    let value: Int?
    let target: Int?
    let tint: Color
    /// Probe tiles open their settings; the grill tile does not. Without a mark
    /// the two look identical and the target control is undiscoverable.
    var isEditable = false
    /// Sub-line shown when there is no reading and no target.
    var placeholder = "no reading"
    /// Optional second line, e.g. the grate-level estimate.
    var secondary: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if isEditable {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(theme.textMuted)
                }
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value.map(String.init) ?? "—")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(value == nil ? theme.textMuted : tint)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if value != nil {
                    Text("°").font(.footnote).foregroundStyle(theme.textMuted)
                }
            }

            if let secondary {
                // Two lines: an ETA plus a finish time doesn't fit one line in
                // a narrow tile, and truncating it to "estimate after ~2…" is
                // worse than wrapping.
                Text(secondary)
                    .font(.caption2)
                    .foregroundStyle(theme.textMuted)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Always rendered, so tiles with and without a target line up.
            // `placeholder` is per-tile: "no probe" is right under Probe 2 and
            // nonsense under Grill, which is what it used to say.
            Text(target.map { "target \($0)°" } ?? (value == nil ? placeholder : " "))
                .font(.caption2)
                .foregroundStyle(theme.textMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        // maxHeight so every tile in a row matches the tallest: a probe tile
        // carries an ETA line the grill tile doesn't, and the ragged bottoms
        // read as a layout bug.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
    }
}

/// The primary action button style, themed.
struct GrillButtonStyle: ButtonStyle {
    @Environment(\.theme) private var theme
    var tint: Color?
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        let fill = prominent ? (tint ?? theme.accent) : theme.surfaceRaised
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : (tint ?? theme.text))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(prominent ? .clear : theme.border, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A banner for an error or an alert that needs acknowledging.
struct NoticeBanner: View {
    @Environment(\.theme) private var theme

    let text: String
    let tint: Color
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").foregroundStyle(theme.textMuted)
                }
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.4), lineWidth: 1))
    }
}

/// Elapsed time of the current cook — the desktop app's header session clock.
///
/// Driven by `TimelineView` rather than a `Timer` publisher: this view lives in
/// the navigation bar's principal slot, and a toolbar item does not reliably sit
/// in the update path for `onReceive`, so the timer fired but the label never
/// redrew — it sat at 00:00:00 through a running cook. TimelineView schedules
/// its own redraws and works anywhere.
struct SessionClock: View {
    @Environment(\.theme) private var theme

    let start: Date?
    let isRunning: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            // No icon: the flame now means "prime" in the toolbar, and two
            // flames a few points apart meaning different things is worse than
            // none. Whether the grill is lit is carried by the reading itself.
            Text(elapsed(at: context.date))
                .font(.system(.body, design: .monospaced).weight(.semibold))
                .foregroundStyle(isRunning ? theme.text : theme.textMuted)
                .contentTransition(.numericText())
                .monospacedDigit()
                .accessibilityLabel("Cook time \(elapsed(at: context.date))")
        }
    }

    private func elapsed(at now: Date) -> String {
        guard let start else { return "--:--:--" }
        let s = Int(max(0, now.timeIntervalSince(start)))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// Lets a bare `Int` drive `.sheet(item:)`.
///
/// Cheaper than a wrapper struct for "which probe is being edited", and the
/// identity is genuinely the value.
extension Int: @retroactive Identifiable {
    public var id: Int { self }
}

/// A big −/value/+ control, shared by the grill and probe target sheets.
///
/// Extracted because both sheets had the same stepper with the same 54pt round
/// buttons; two copies would have drifted the moment one was tuned.
struct TargetStepper: View {
    @Environment(\.theme) private var theme

    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    /// Small line under the number — a range, or the current reading.
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            button("minus", enabled: value > range.lowerBound) {
                value = max(range.lowerBound, value - step)
            }
            VStack(spacing: 0) {
                Text("\(value)°")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .foregroundStyle(theme.text)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(theme.textMuted)
                }
            }
            .frame(maxWidth: .infinity)
            button("plus", enabled: value < range.upperBound) {
                value = min(range.upperBound, value + step)
            }
        }
    }

    private func button(_ icon: String, enabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title2.weight(.semibold))
                .frame(width: 54, height: 54)
                .background(theme.surfaceRaised, in: Circle())
                .foregroundStyle(enabled ? theme.text : theme.inactive)
        }
        .disabled(!enabled)
        .accessibilityLabel(icon == "plus" ? "Raise" : "Lower")
    }
}

/// A scroll view whose content is at least as tall as the screen.
///
/// Every screen in the app uses this so they fill consistently: content shorter
/// than the viewport stretches to it (so a `Spacer` genuinely pushes a footer to
/// the bottom instead of leaving it floating mid-screen), and content taller
/// than it scrolls as normal.
///
/// `readingWidth` caps the column for prose-heavy screens — a measure for text,
/// never for the data-dense dashboard, which should use the width it has.
struct FillingScrollView<Content: View>: View {
    var spacing: CGFloat = 12
    var readingWidth: CGFloat?
    @ViewBuilder var content: () -> Content

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: spacing) {
                    content()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: readingWidth ?? .infinity)
                .frame(maxWidth: .infinity)
                // On the VStack itself, not a wrapper: this is what lets an
                // interior Spacer expand rather than the whole block centring.
                .frame(minHeight: proxy.size.height)
            }
        }
    }
}
