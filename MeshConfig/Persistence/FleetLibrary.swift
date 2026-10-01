import Combine
import Foundation

/// Saved fleet profiles. JSON holds `PSKReference.keychainAccount` only — never key bytes.
@MainActor
final class FleetLibrary: ObservableObject {
    @Published private(set) var profiles: [FleetProfile] = []

    private let fileName = "fleet-profiles.json"
    private let didSeedKey = "didSeedFleetProfile"
    private let lastProfileKey = "lastProfileID"

    init() {
        load()
        if profiles.isEmpty && !UserDefaults.standard.bool(forKey: didSeedKey) {
            _ = createTAKProfile()
            UserDefaults.standard.set(true, forKey: didSeedKey)
        }
    }

    func profile(id: UUID) -> FleetProfile? {
        profiles.first { $0.id == id }
    }

    var lastUsedProfileID: UUID? {
        UserDefaults.standard.string(forKey: lastProfileKey).flatMap(UUID.init(uuidString:))
    }

    func rememberLastUsed(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: lastProfileKey)
    }

    @discardableResult
    func createTAKProfile() -> FleetProfile {
        var profile = BuiltInProfiles.takTracker(
            region: Self.defaultRegion,
            displayUnits: Self.defaultUnits
        )
        profile.applyTAKTemplateLocks()
        try? FleetPSKStore.ensurePSK(for: &profile)
        profiles.append(profile)
        rememberLastUsed(profile.id)
        persist()
        return profile
    }

    func duplicate(_ source: FleetProfile) {
        var copy = source
        copy.id = UUID()
        copy.name = source.name + " Copy"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        // One Keychain item per profile id. Do not reuse the source account.
        copy.channel.pskRef = .empty
        copy.mqtt.passwordRef = .empty
        copy.wifiNetworks = copy.wifiNetworks.map { network in
            WifiNetwork(id: UUID(), ssid: network.ssid, pskRef: .empty)
        }
        copy.applyTAKTemplateLocks()
        try? FleetPSKStore.ensurePSK(for: &copy)
        profiles.append(copy)
        persist()
    }

    func delete(_ profile: FleetProfile) {
        try? FleetPSKStore.deletePSK(for: profile.id)
        try? GatewaySecretStore.deleteAll(for: profile)
        profiles.removeAll { $0.id == profile.id }
        if lastUsedProfileID == profile.id {
            UserDefaults.standard.removeObject(forKey: lastProfileKey)
        }
        persist()
    }

    func replace(_ profile: FleetProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var clean = profile
        clean.applyTAKTemplateLocks()
        profiles[index] = clean
        persist()
    }

    func persist() {
        var clean = profiles
        for index in clean.indices {
            clean[index].applyTAKTemplateLocks()
        }
        profiles = clean
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(clean)
            #if DEBUG
            if let text = String(data: data, encoding: .utf8) {
                assert(!text.contains("\"exportableBase64\" : \""), "Profile JSON must not embed a PSK.")
            }
            #endif
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Persistence failure leaves the in-memory list intact. No key material is logged.
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            var decoded = try decoder.decode([FleetProfile].self, from: data)
            for index in decoded.indices {
                decoded[index].channel.pskRef.exportableBase64 = nil
                decoded[index].applyTAKTemplateLocks()
            }
            profiles = decoded
        } catch {
            let corrupt = fileURL.appendingPathExtension("corrupt")
            try? FileManager.default.removeItem(at: corrupt)
            try? FileManager.default.moveItem(at: fileURL, to: corrupt)
            profiles = []
        }
    }

    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MeshConfig", isDirectory: true)
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }

    static var defaultRegion: LoRaRegion {
        let raw = UserDefaults.standard.string(forKey: "defaultRegion") ?? LoRaRegion.us.rawValue
        return LoRaRegion(rawValue: raw) ?? .us
    }

    static var defaultUnits: DisplayUnits {
        let raw = UserDefaults.standard.string(forKey: "defaultUnits") ?? DisplayUnits.imperial.rawValue
        return DisplayUnits(rawValue: raw) ?? .imperial
    }
}
