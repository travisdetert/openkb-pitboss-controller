import SwiftUI
import Charts
import PitBossKit

/// The cook curve: grill temperature against its setpoint, with each probe.
///
/// The setpoint is drawn as a dashed reference rather than another data series —
/// it is the target being tracked, not a measurement, and drawing it the same
/// weight as the grill line makes an overshoot hard to read.
struct CookChartView: View {
    @Environment(\.theme) private var theme
    let samples: [CookSample]
    let probes: [Int]
    let range: ClosedRange<Int>?
    /// Shown in place of the curve when there is nothing to draw yet.
    var emptyMessage = "Collecting data — the curve appears after a few readings."

    private var probeColors: [Int: Color] {
        [1: theme.green, 2: theme.accent, 3: theme.amber, 4: theme.red]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("COOK CURVE")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.textMuted)
                Spacer()
                legend
            }

            if samples.count < 2 {
                // Say why it's empty rather than showing an empty frame.
                VStack(spacing: 8) {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.title2)
                        .foregroundStyle(theme.inactive)
                    Text(emptyMessage)
                        .font(.footnote)
                        .foregroundStyle(theme.textMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
    }

    private var legend: some View {
        HStack(spacing: 10) {
            legendDot("Grill", theme.flame)
            ForEach(probes, id: \.self) { p in
                legendDot("P\(p)", probeColors[p] ?? theme.accent)
            }
        }
    }

    private func legendDot(_ label: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).font(.caption2).foregroundStyle(theme.textMuted)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { sample in
                if let temp = sample.grillTemp {
                    LineMark(x: .value("Time", sample.at),
                             y: .value("Temp", temp),
                             series: .value("Series", "grill"))
                        .foregroundStyle(theme.flame)
                        .interpolationMethod(.monotone)
                }
                if let set = sample.grillSetTemp {
                    LineMark(x: .value("Time", sample.at),
                             y: .value("Temp", set),
                             series: .value("Series", "set"))
                        .foregroundStyle(theme.textMuted)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                ForEach(probes, id: \.self) { probe in
                    if let temp = sample.probes[probe] {
                        LineMark(x: .value("Time", sample.at),
                                 y: .value("Temp", temp),
                                 series: .value("Series", "p\(probe)"))
                            .foregroundStyle(probeColors[probe] ?? theme.accent)
                            .interpolationMethod(.monotone)
                    }
                }
            }
        }
        .chartYScale(domain: range.map { Double($0.lowerBound)...Double($0.upperBound) }
                     ?? 0...500)
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine().foregroundStyle(theme.border)
                AxisValueLabel {
                    if let v = value.as(Int.self) {
                        Text("\(v)°").font(.caption2).foregroundStyle(theme.textMuted)
                    }
                }
            }
        }
        .chartXAxis {
            // A fixed count, not automatic: the default packed six labels into
            // a landscape chart and they ran together into "9:00 AM9:05 AM".
            AxisMarks(preset: .aligned, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(theme.border.opacity(0.5))
                AxisValueLabel(anchor: .top) {
                    if let d = value.as(Date.self) {
                        Text(d, format: .dateTime.hour().minute())
                            .font(.caption2).foregroundStyle(theme.textMuted)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// What each component is doing now, and when it ran.
///
/// One panel, not two: a lamp row and a timeline row were showing the same
/// three components — once as "now", once as "history" — in separate boxes with
/// separate titles. Combined, each component is a single line: state dot, name,
/// and the bar of when it ran.
///
/// Activity is latched between samples, so a brief auger pulse still draws a
/// bar; reading its instantaneous value every 5s would miss most feed cycles
/// and make a working grill look idle.
struct ActivityTimelineView: View {
    @Environment(\.theme) private var theme

    let samples: [CookSample]
    let augerRuns: [(start: Date, end: Date)]
    let fanRuns: [(start: Date, end: Date)]
    let igniterRuns: [(start: Date, end: Date)]

    /// Live states. Nil for a past cook, where there is no "now".
    var augerOn: Bool? = nil
    var fanOn: Bool? = nil
    var igniterOn: Bool? = nil
    var primeOn: Bool? = nil
    var lightOn: Bool? = nil

    private var span: (start: Date, end: Date)? {
        guard let first = samples.first?.at, let last = samples.last?.at, last > first else { return nil }
        return (first, last)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("ACTIVITY")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.textMuted)
                Spacer(minLength: 0)
                // Components with no recorded history ride in the header rather
                // than claiming a full row with an empty track.
                if let primeOn { miniLamp("Prime", primeOn, theme.green) }
                if let lightOn { miniLamp("Light", lightOn, theme.green) }
            }

            // Spacers, not a fixed gap: in the landscape side column this card
            // is stretched to match the chart, and spreading the rows fills it
            // without distorting them.
            VStack(spacing: 8) {
                row("Auger", augerRuns, theme.amber, augerOn)
                Spacer(minLength: 0)
                row("Fan", fanRuns, theme.accent, fanOn)
                Spacer(minLength: 0)
                row("Igniter", igniterRuns, theme.flame, igniterOn)
            }
            .frame(maxHeight: .infinity)

            if let span {
                HStack {
                    Text(span.start, format: .dateTime.hour().minute())
                    Spacer()
                    Text(span.end, format: .dateTime.hour().minute())
                }
                .font(.caption2)
                .foregroundStyle(theme.textMuted)
            } else {
                Text("Activity history appears after a few readings.")
                    .font(.caption2)
                    .foregroundStyle(theme.textMuted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
    }

    private func miniLamp(_ label: String, _ isOn: Bool, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOn ? tint : theme.inactive)
                .frame(width: 8, height: 8)
                .shadow(color: isOn ? tint.opacity(0.7) : .clear, radius: 4)
            Text(label)
                .font(.caption2)
                .foregroundStyle(isOn ? theme.text : theme.textMuted)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(isOn ? "on" : "off")")
    }

    private func row(_ label: String, _ runs: [(start: Date, end: Date)],
                     _ color: Color, _ isOn: Bool?) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isOn == true ? color : theme.inactive)
                .frame(width: 8, height: 8)
                .shadow(color: isOn == true ? color.opacity(0.7) : .clear, radius: 4)
            Text(label)
                .font(.caption)
                .foregroundStyle(isOn == true ? theme.text : theme.textMuted)
                .frame(width: 52, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.surfaceRaised)
                    if let span {
                        let total = span.end.timeIntervalSince(span.start)
                        ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                            let x = run.start.timeIntervalSince(span.start) / total * geo.size.width
                            // A single-sample pulse would round to zero width,
                            // so every run gets a visible minimum.
                            let w = max(2, run.end.timeIntervalSince(run.start) / total * geo.size.width)
                            Capsule()
                                .fill(color)
                                .frame(width: w)
                                .offset(x: min(x, geo.size.width - 2))
                        }
                    }
                }
            }
            // Fixed: letting the tracks themselves grow turned them into fat
            // pills. The spacing between rows absorbs extra height instead.
            .frame(height: 14)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(isOn == true ? "running now, " : "")\(runs.count) active period\(runs.count == 1 ? "" : "s")")
    }
}
