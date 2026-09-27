import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var library: FleetLibrary
    @AppStorage("defaultRegion") private var region = LoRaRegion.us.rawValue
    @AppStorage("defaultUnits") private var units = DisplayUnits.imperial.rawValue

    private let guideURL = URL(string: "https://chaoskoalas.com/advanced-guides/meshtastic-atak-integration/")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(AppVersion.display)
                        .font(.title2.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                } footer: {
                    Text("This is the Mesh Config build on this phone. After a git pull and Run, it should match the version in the Xcode project.")
                }
                Section("New profiles") {
                    Picker("Default region", selection: $region) {
                        Text("US").tag(LoRaRegion.us.rawValue)
                        Text("EU 868").tag(LoRaRegion.eu868.rawValue)
                    }
                    Picker("Default units", selection: $units) {
                        Text("Imperial").tag(DisplayUnits.imperial.rawValue)
                        Text("Metric").tag(DisplayUnits.metric.rawValue)
                    }
                    LabeledContent("Last profile") {
                        Text(lastProfileName)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("About") {
                    Link("Chaos Koalas ATAK over Meshtastic guide", destination: guideURL)
                    Text("ATAK or iTAK on this phone talks to the Local TAK Server inside the Meshtastic phone app. That server is not part of Mesh Config, and a radio’s Wi‑Fi is not a home TAK server.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Firmware") {
                    Text("Firmware flash is separate from this app. Heltec WiFi LoRa 32 V3 is flashed from a computer. Heltec Mesh Node T114 and SenseCAP T1000-E use their own update paths. The T114 does not have Wi‑Fi. Bluetooth setup is the same for all three.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section("Key") {
                    Text("Each profile has one AES-256 key in the iOS Keychain (service com.meshconfig.fleet.psk). Mesh Config never shows the key, and the saved profile does not contain it. There is no paste or import in this version. Rotate overwrites the key; then re-apply every radio.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
        }
    }

    private var lastProfileName: String {
        guard let id = library.lastUsedProfileID, let profile = library.profile(id: id) else {
            return "None"
        }
        return profile.name
    }
}

/// Marketing version and build from the app bundle (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`).
enum AppVersion {
    static var display: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let marketing = short?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let number = build?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if marketing.isEmpty && number.isEmpty { return "Version unknown" }
        if number.isEmpty { return "Version \(marketing)" }
        if marketing.isEmpty { return "Version (\(number))" }
        return "Version \(marketing) (\(number))"
    }
}
