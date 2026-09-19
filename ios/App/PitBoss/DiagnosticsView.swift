import SwiftUI
import PitBossKit

/// The unified log, on screen.
///
/// A phone has no terminal to tail, so this is the equivalent of the desktop
/// app's `/tmp/openkb-pit-boss.log`: one place where every subsystem's output
/// lands, readable without Xcode and shareable when something needs reporting.
struct DiagnosticsView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var contents = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(contents.isEmpty ? "Nothing logged yet." : contents)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(theme.background)
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack {
                        ShareLink(item: contents) { Image(systemName: "square.and.arrow.up") }
                            .disabled(contents.isEmpty)
                        Button {
                            PitBossLog.clear()
                            contents = ""
                        } label: {
                            Image(systemName: "trash")
                        }
                        .accessibilityLabel("Clear log")
                    }
                }
            }
        }
        .task { contents = PitBossLog.contents() }
    }
}
