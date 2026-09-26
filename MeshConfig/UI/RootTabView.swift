import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var navigation: AppNavigation
    @State private var showPSKIntro = !UserDefaults.standard.bool(forKey: Self.introKey)

    private static let introKey = "didShowPSKExplanation"

    var body: some View {
        TabView(selection: $navigation.tab) {
            ProfilesListView()
                .tabItem { Label("Profiles", systemImage: "list.bullet.rectangle") }
                .tag(AppTab.profiles)
            DevicesRosterView()
                .tabItem { Label("Devices", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppTab.devices)
            ApplySetupView()
                .tabItem { Label("Apply", systemImage: "dot.radiowaves.left.and.right") }
                .tag(AppTab.apply)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(AppTab.settings)
        }
        .sheet(isPresented: $showPSKIntro) {
            PSKIntroView {
                UserDefaults.standard.set(true, forKey: Self.introKey)
                showPSKIntro = false
            }
            .interactiveDismissDisabled()
        }
    }
}

struct PSKIntroView: View {
    var onContinue: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Text("One key for the fleet")
                    .font(.title.bold())
                Text("Mesh Config generates one AES-256 channel key for each profile and stores it in the iOS Keychain on this phone. The saved profile file keeps only a reference, not the key.")
                Text("Apply that same profile to each radio over Bluetooth, one radio at a time. The key is not shown, pasted, or imported. If you rotate it, re-apply every radio or the mesh will split.")
                Text("Role is chosen for each radio: TAK Tracker for a standalone, or TAK when this phone will run ATAK/iTAK with the Meshtastic app’s Local TAK Server.")
                Spacer()
                Button("Continue", action: onContinue)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(24)
            .navigationTitle("Mesh Config")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct RoleChip: View {
    var role: DeviceRole

    var body: some View {
        Text(role.chipTitle)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.22), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch role {
        case .tak: return .orange
        case .takTracker: return .teal
        case .clientBase: return .secondary
        }
    }
}

struct StatusBadge: View {
    var status: DeviceConfigStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .configured: return .green
        case .failed: return .red
        case .pending: return .orange
        case .roleChangedNeedsReapply: return .yellow
        }
    }
}
