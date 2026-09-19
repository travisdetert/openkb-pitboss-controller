import SwiftUI
import PitBossKit

/// Routes between setup and the dashboard, and owns the chrome both share.
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Group {
                if let error = model.setupError {
                    // The catalogue failed to load — nothing else can work.
                    VStack(spacing: 16) {
                        NoticeBanner(text: error, tint: theme.red)
                        Text("The bundled grill catalogue could not be read. Reinstalling the app is the fix.")
                            .font(.footnote)
                            .foregroundStyle(theme.textMuted)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else if let controller = model.controller {
                    if model.isConfigured {
                        DashboardView(controller: controller)
                    } else {
                        ConnectView(controller: controller)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(theme.background)
        }
        .tint(theme.accent)
    }
}

/// First run: find the grill. That is the whole setup.
///
/// There is deliberately no model picker. The control board is read from the
/// advertised name and fully determines decoding and commands (every board in
/// the catalogue has exactly one decoding behaviour), and the firmware does not
/// report a chassis model at all. Asking for one would be asking the user to
/// answer a question the protocol already answers.
struct ConnectView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.theme) private var theme
    @ObservedObject var controller: GrillController

    @State private var isScanning = false

    var body: some View {
        FillingScrollView(spacing: 20, readingWidth: 620) {
            VStack(alignment: .leading, spacing: 20) {
                header

                if case .failed(let message) = controller.phase {
                    NoticeBanner(text: message, tint: theme.red)
                }

                Button {
                    Task {
                        isScanning = true
                        await controller.scan()
                        isScanning = false
                    }
                } label: {
                    HStack {
                        if isScanning { ProgressView().tint(.white) }
                        Text(isScanning ? "Scanning…" : "Scan for grills")
                    }
                }
                .buttonStyle(GrillButtonStyle(prominent: true))
                .disabled(isScanning)

                if isScanning && controller.discovered.isEmpty {
                    // Something to look at while the 8s scan runs, instead of a
                    // button that just says "Scanning…" over dead space.
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Looking for grills nearby…")
                            .font(.footnote)
                            .foregroundStyle(theme.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
                }

                if !controller.discovered.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TAP YOUR GRILL TO CONNECT")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(theme.textMuted)
                        ForEach(controller.discovered) { grill in
                            grillRow(grill)
                        }
                    }
                }
            }
            .padding()
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Set up")
        .toolbar { ThemeMenu() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connect your grill")
                .font(.title2.weight(.bold))
                .foregroundStyle(theme.text)
            Text("Pit Boss talks to the grill directly over Bluetooth. No account, no cloud — so your phone needs to be within range of the grill.")
                .font(.subheadline)
                .foregroundStyle(theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func grillRow(_ grill: DiscoveredGrill) -> some View {
        Button {
            PitBossLog.write("[app] connect requested — \(grill.name)")
            model.grillName = grill.name
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "flame.circle.fill")
                    .font(.title2)
                    .foregroundStyle(theme.flame)
                VStack(alignment: .leading, spacing: 2) {
                    // The advertised name embeds the MAC and is long — it is the
                    // identifier, so give it room to be read in full.
                    Text(grill.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 4) {
                        if let board = GrillCatalog.board(fromAdvertisedName: grill.name) {
                            Text("\(board) board · signal \(grill.rssi) dBm")
                        } else {
                            Text("signal \(grill.rssi) dBm")
                        }
                        if grill.rssi < -85 {
                            Text("· weak, move closer").foregroundStyle(theme.amber)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(theme.textMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(theme.textMuted)
            }
            .padding(12)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// The theme control, available from every screen.
struct ThemeMenu: ToolbarContent {
    @AppStorage("themePreference") private var themeRaw = ThemePreference.system.rawValue

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Appearance", selection: $themeRaw) {
                    ForEach(ThemePreference.allCases) { pref in
                        Text(pref.label).tag(pref.rawValue)
                    }
                }
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .accessibilityLabel("Appearance")
        }
    }
}
