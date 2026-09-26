import SwiftUI

enum AppTab: Hashable {
    case profiles
    case devices
    case apply
    case settings
}

struct ApplyPrefill: Equatable {
    var profileID: UUID
    var role: DeviceRole
    var peripheralID: UUID?
    var rosterDeviceID: UUID
    var token: UUID
}

@MainActor
final class AppNavigation: ObservableObject {
    @Published var tab: AppTab = .profiles
    @Published var applyPrefill: ApplyPrefill?
}

@main
struct MeshConfigApp: App {
    @StateObject private var library = FleetLibrary()
    @StateObject private var roster = DeviceRosterStore()
    @StateObject private var driver = ApplyDriver()
    @StateObject private var navigation = AppNavigation()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(library)
                .environmentObject(roster)
                .environmentObject(driver)
                .environmentObject(navigation)
                .onChange(of: scenePhase) { _, phase in
                    guard phase != .active else { return }
                    library.persist()
                    roster.persist()
                }
        }
    }
}
