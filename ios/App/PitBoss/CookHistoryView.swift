import SwiftUI
import PitBossKit

/// Past cooks, read back from disk.
struct CookHistoryView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var controller: GrillController

    @State private var cooks: [CookMeta] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if cooks.isEmpty {
                    // Explain the emptiness — a cook is only recorded once the
                    // grill actually powers on.
                    VStack(spacing: 10) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.largeTitle)
                            .foregroundStyle(theme.textMuted)
                        Text("No cooks recorded yet")
                            .font(.headline)
                            .foregroundStyle(theme.text)
                        Text("A cook is recorded from the moment the grill powers on until it powers off.")
                            .font(.footnote)
                            .foregroundStyle(theme.textMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        if let error {
                            NoticeBanner(text: error, tint: theme.red) { self.error = nil }
                        }
                        ForEach(cooks) { cook in
                            NavigationLink {
                                CookDetailView(controller: controller, cook: cook)
                            } label: {
                                row(cook)
                            }
                        }
                        .onDelete(perform: delete)
                    }
                }
            }
            .background(theme.background)
            .navigationTitle("Cook history")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                if !cooks.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) { EditButton() }
                }
            }
        }
        .task { cooks = controller.listCooks() }
    }

    private func row(_ cook: CookMeta) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(cook.name ?? cook.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.body.weight(.medium))
                .foregroundStyle(theme.text)
            HStack(spacing: 6) {
                if cook.name != nil {
                    Text(cook.startedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let duration = cook.duration {
                    Text("· \(durationLabel(duration))")
                }
                Text("· \(cook.sampleCount) readings")
                if cook.endedAt == nil {
                    Text("· recording").foregroundStyle(theme.green)
                }
            }
            .font(.caption)
            .foregroundStyle(theme.textMuted)
        }
    }

    private func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let cook = cooks[index]
            do { try controller.deleteCook(cook.id) }
            catch { self.error = error.localizedDescription }
        }
        cooks = controller.listCooks()
    }
}

/// One past cook: its curve and its component activity.
struct CookDetailView: View {
    @Environment(\.theme) private var theme
    @ObservedObject var controller: GrillController
    let cook: CookMeta

    @State private var samples: [CookSample] = []
    @State private var name: String = ""

    private var probes: [Int] {
        Set(samples.flatMap(\.probes.keys)).sorted()
    }

    /// Recomputed from the loaded samples — a past cook has no live controller
    /// state to borrow a range from.
    private var range: ClosedRange<Int>? {
        var values: [Int] = []
        for s in samples {
            if let v = s.grillTemp { values.append(v) }
            if let v = s.grillSetTemp { values.append(v) }
            values.append(contentsOf: s.probes.values)
        }
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let pad = max(10, (hi - lo) / 10)
        return (lo - pad)...(hi + pad)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                TextField("Name this cook", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { try? controller.renameCook(cook.id, to: name) }

                CookChartView(samples: samples, probes: probes, range: range)
                ActivityTimelineView(samples: samples,
                                     augerRuns: runs(\.auger),
                                     fanRuns: runs(\.fan),
                                     igniterRuns: runs(\.igniter))
                summary
            }
            .padding()
        }
        .background(theme.background)
        .navigationTitle(cook.startedAt.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            samples = (try? controller.readCook(cook.id)) ?? []
            name = cook.name ?? ""
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SUMMARY")
                .font(.caption.weight(.bold))
                .foregroundStyle(theme.textMuted)
            let temps = samples.compactMap(\.grillTemp)
            if let peak = temps.max() {
                line("Peak grill", "\(peak)°")
            }
            if !temps.isEmpty {
                line("Average grill", "\(temps.reduce(0, +) / temps.count)°")
            }
            if let duration = cook.duration {
                let total = Int(duration)
                line("Duration", total >= 3600 ? "\(total / 3600)h \((total % 3600) / 60)m" : "\(total / 60)m")
            }
            line("Readings", "\(samples.count)")
            if let device = cook.device { line("Grill", device) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.border, lineWidth: 1))
    }

    private func line(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(theme.textMuted)
            Spacer(minLength: 8)
            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(theme.text)
        }
    }

    /// Same run-flattening the live timeline uses, over loaded samples.
    private func runs(_ component: KeyPath<CookSample, Bool>) -> [(start: Date, end: Date)] {
        var out: [(Date, Date)] = []
        var start: Date?
        for s in samples {
            if s[keyPath: component] {
                if start == nil { start = s.at }
            } else if let began = start {
                out.append((began, s.at)); start = nil
            }
        }
        if let began = start, let last = samples.last {
            out.append((began, max(last.at, began.addingTimeInterval(5))))
        }
        return out
    }
}
