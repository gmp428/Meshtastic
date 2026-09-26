import Foundation

/// Radios remembered on this phone. Removing one does not factory-reset the radio.
@MainActor
final class DeviceRosterStore: ObservableObject {
    @Published private(set) var devices: [ConfiguredDevice] = []

    private let fileName = "configured-devices.json"

    init() {
        load()
    }

    func device(id: UUID) -> ConfiguredDevice? {
        devices.first { $0.id == id }
    }

    func upsertAttempt(
        existingID: UUID?,
        peripheralID: UUID?,
        displayName: String,
        profileID: UUID,
        role: DeviceRole,
        status: DeviceConfigStatus,
        simulatedNote: Bool
    ) {
        let matchIndex = devices.firstIndex { device in
            if let existingID, device.id == existingID { return true }
            if let peripheralID, device.peripheralID == peripheralID { return true }
            return false
        }

        if let matchIndex {
            devices[matchIndex].displayName = displayName
            devices[matchIndex].peripheralID = peripheralID ?? devices[matchIndex].peripheralID
            devices[matchIndex].profileID = profileID
            devices[matchIndex].role = role
            switch status {
            case .configured:
                devices[matchIndex].markConfigured()
            case .failed:
                devices[matchIndex].markFailed()
            case .pending, .roleChangedNeedsReapply:
                devices[matchIndex].lastStatus = status
            }
        } else {
            var notes = ""
            if simulatedNote {
                notes = "Simulated DEBUG session. Not a real radio."
            }
            var created = ConfiguredDevice(
                peripheralID: peripheralID,
                displayName: displayName,
                profileID: profileID,
                role: role,
                notes: notes
            )
            switch status {
            case .configured:
                created.markConfigured()
            case .failed:
                created.markFailed()
            case .pending, .roleChangedNeedsReapply:
                created.lastStatus = status
            }
            devices.append(created)
        }
        persist()
    }

    /// Role edits stay on the phone until Apply writes Device config and verify passes.
    func setRole(_ role: DeviceRole, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].setRole(role)
        persist()
    }

    func setProfile(_ profileID: UUID, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        guard devices[index].profileID != profileID else { return }
        devices[index].profileID = profileID
        devices[index].lastStatus = .pending
        persist()
    }

    func setNotes(_ notes: String, for id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].notes = notes
        persist()
    }

    /// In-app only. The radio keeps whatever config it already has.
    func remove(_ id: UUID) {
        devices.removeAll { $0.id == id }
        persist()
    }

    /// After PSK rotation the radios still have the previous key until the user re-applies.
    func markProfileNeedsReapply(_ profileID: UUID) {
        for index in devices.indices where devices[index].profileID == profileID {
            devices[index].lastStatus = .pending
        }
        persist()
    }

    func persist() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(devices)
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // Leave the in-memory roster intact.
        }
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? decoder.decode([ConfiguredDevice].self, from: data) else {
            return
        }
        devices = decoded
    }

    private var directoryURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("MeshConfig", isDirectory: true)
    }

    private var fileURL: URL {
        directoryURL.appendingPathComponent(fileName)
    }
}
