import SwiftUI
import PitBossKit

/// Picks a cut, then its target temperature.
///
/// Two steps, not one expanding list. An earlier version expanded the chosen
/// cut inline, which left a screen full of unrelated meats around the thing you
/// had just selected — picking brisket shouldn't leave salmon on screen. The
/// list narrows to one cut, and that cut's screen is only about that cut.
struct CutPickerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    /// Called with the chosen target and the cut's name, so the probe can be
    /// labelled "Brisket" without a second step.
    var onPick: (MeatCut, MeatTarget) -> Void

    @State private var query = ""

    private var results: [MeatCut] { MeatCatalog.search(query) }

    var body: some View {
        NavigationStack {
            List {
                ForEach(MeatCategory.allCases) { category in
                    let cuts = results.filter { $0.category == category }
                    if !cuts.isEmpty {
                        Section {
                            ForEach(cuts) { cut in
                                NavigationLink {
                                    CutDetailView(cut: cut) { target in
                                        onPick(cut, target)
                                        dismiss()
                                    }
                                } label: {
                                    row(cut)
                                }
                            }
                        } header: {
                            HStack {
                                Text(category.label)
                                if let floor = MeatCatalog.safeMinimum(for: category) {
                                    Spacer()
                                    Text("safe min \(floor)°")
                                        .font(.caption2)
                                        .foregroundStyle(theme.textMuted)
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Brisket, chicken thighs, salmon…")
            .navigationTitle("Choose a cut")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func row(_ cut: MeatCut) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(cut.name)
                .font(.body.weight(.medium))
                .foregroundStyle(theme.text)
            HStack(spacing: 6) {
                if let suggested = cut.suggested {
                    Text("\(suggested.temperature)° · \(suggested.label)")
                }
                if !cut.methods.isEmpty {
                    Text("· \(cut.methods.count == 1 ? cut.methods[0].name : "\(cut.methods.count) methods")")
                        .foregroundStyle(theme.flame)
                }
            }
            .font(.caption)
            .foregroundStyle(theme.textMuted)
        }
    }
}

/// One cut: its targets, why they're what they are, and any methods.
struct CutDetailView: View {
    @Environment(\.theme) private var theme

    let cut: MeatCut
    var onPick: (MeatTarget) -> Void

    @State private var method: CookMethod?

    var body: some View {
        FillingScrollView(spacing: 16, readingWidth: 620) {
            VStack(alignment: .leading, spacing: 16) {
                if let note = cut.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(theme.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("TARGET")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(theme.textMuted)
                    ForEach(cut.targets) { target in
                        targetRow(target)
                    }
                }

                if !cut.methods.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("METHODS")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.textMuted)
                        ForEach(cut.methods) { m in
                            Button { method = m } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "list.number").foregroundStyle(theme.flame)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(m.name)
                                                .font(.subheadline.weight(.semibold))
                                                .foregroundStyle(theme.text)
                                            if let duration = m.durationLabel {
                                                Text(duration).font(.caption2)
                                                    .foregroundStyle(theme.textMuted)
                                            }
                                        }
                                        Text(m.summary)
                                            .font(.caption)
                                            .foregroundStyle(theme.textMuted)
                                            .fixedSize(horizontal: false, vertical: true)
                                            .multilineTextAlignment(.leading)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right")
                                        .font(.caption2).foregroundStyle(theme.textMuted)
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .stroke(theme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let floor = cut.safeFloor {
                    Text("USDA safe minimum for \(cut.category.label.lowercased()): \(floor)°.")
                        .font(.caption2)
                        .foregroundStyle(theme.textMuted)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.background)
        .navigationTitle(cut.name)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $method) { MethodView(method: $0) }
    }

    private func targetRow(_ target: MeatTarget) -> some View {
        let belowFloor = MeatCatalog.isBelowSafeMinimum(target, for: cut)
        return Button {
            onPick(target)
        } label: {
            HStack(spacing: 12) {
                Text("\(target.temperature)°")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint(for: target.kind))
                    .frame(width: 62, alignment: .leading)

                VStack(alignment: .leading, spacing: 1) {
                    Text(target.label)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(theme.text)
                    Text(kindLabel(target.kind))
                        .font(.caption2)
                        .foregroundStyle(theme.textMuted)
                }

                Spacer(minLength: 0)

                if belowFloor, let floor = cut.safeFloor {
                    // Named, not blocked. A rare steak is a real choice.
                    Label("under \(floor)°", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(theme.amber)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func tint(for kind: TargetKind) -> Color {
        switch kind {
        case .safeMinimum: return theme.green
        case .doneness:    return theme.accent
        case .texture:     return theme.flame
        }
    }

    private func kindLabel(_ kind: TargetKind) -> String {
        switch kind {
        case .safeMinimum: return "USDA safe minimum"
        case .doneness:    return "doneness preference"
        case .texture:     return "cooked for texture"
        }
    }
}
