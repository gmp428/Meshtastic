import Foundation

#if DEBUG
/// DEBUG-only apply transport. It does not talk to a radio and it does not keep PSK bytes.
/// Scan rows are labeled "(DEBUG)" so they cannot be mistaken for hardware.
@MainActor
final class SimulatedMeshtasticTransport: FleetRadioTransport {
    static let heltecV3 = UUID(uuidString: "A1111111-1111-4111-8111-111111111111")!
    static let t1000e = UUID(uuidString: "A2222222-2222-4222-8222-222222222222")!

    var onDiscovered: (@MainActor (DiscoveredRadio) -> Void)?
    var onBluetoothBlocked: (@MainActor (String?) -> Void)?
    var onUnexpectedLinkLoss: (@MainActor () -> Void)?

    private var scanTask: Task<Void, Never>?
    private var connectedID: UUID?
    private var wroteLoRa: LoRaSettings?
    private var wroteRole: DeviceRole?
    private var wroteDevice: DeviceSettings?
    private var wrotePosition: PositionSettings?
    private var wroteChannelName: String?
    private var wrotePreciseLocation: Bool?
    private var wrotePSKByteCount: Int?

    func startScan() async {
        onBluetoothBlocked?(nil)
        scanTask?.cancel()
        scanTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self.onDiscovered?(
                DiscoveredRadio(
                    peripheralID: Self.heltecV3,
                    name: "Simulated Heltec V3 (DEBUG)",
                    rssi: -42,
                    isSimulated: true
                )
            )
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self.onDiscovered?(
                DiscoveredRadio(
                    peripheralID: Self.t1000e,
                    name: "Simulated T1000-E (DEBUG)",
                    rssi: -67,
                    isSimulated: true
                )
            )
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
    }

    func connect(peripheralID: UUID) async throws {
        guard peripheralID == Self.heltecV3 || peripheralID == Self.t1000e else {
            throw MeshtasticBLEError.notConnected
        }
        try await pause()
        connectedID = peripheralID
    }

    func handshake() async throws {
        guard connectedID != nil else { throw MeshtasticBLEError.notConnected }
        try await pause(250)
    }

    func setLoRa(_ settings: LoRaSettings) async throws {
        try requireLink()
        try await pause()
        wroteLoRa = settings
    }

    func setDevice(role: DeviceRole, settings: DeviceSettings) async throws {
        try requireLink()
        try await pause()
        wroteRole = role
        wroteDevice = settings
    }

    func setPosition(_ settings: PositionSettings) async throws {
        try requireLink()
        try await pause()
        wrotePosition = settings
    }

    func setDisplay(_ settings: DisplaySettings) async throws {
        try requireLink()
        try await pause()
        _ = settings
    }

    func setPrimaryChannel(_ settings: ChannelSettings, psk: Data) async throws {
        try requireLink()
        guard psk.count == 32 else { throw MeshtasticBLEError.invalidPSKLength }
        try await pause()
        // Record length only. The buffer is not stored.
        wrotePSKByteCount = psk.count
        wroteChannelName = settings.name
        wrotePreciseLocation = settings.preciseLocation
    }

    func readSnapshot() async throws -> DeviceSnapshot {
        try requireLink()
        try await pause(250)
        return DeviceSnapshot(
            modemPreset: wroteLoRa?.modemPreset,
            ignoreMQTT: wroteLoRa?.ignoreMQTT,
            frequencySlot: wroteLoRa?.frequencySlot,
            primaryChannelName: wroteChannelName,
            primaryHasNonDefaultPSK: wrotePSKByteCount == 32,
            preciseLocation: wrotePreciseLocation,
            role: wroteRole,
            rebroadcastMode: wroteDevice?.rebroadcastMode,
            smartPosition: wrotePosition?.smartPosition,
            positionFlags: wrotePosition?.flags
        )
    }

    func disconnect() async {
        stopScan()
        connectedID = nil
    }

    func waitForLinkDrop(timeout: TimeInterval) async -> Bool {
        _ = timeout
        try? await Task.sleep(nanoseconds: 450_000_000)
        connectedID = nil
        return true
    }

    private func requireLink() throws {
        guard connectedID != nil else { throw MeshtasticBLEError.notConnected }
    }

    private func pause(_ milliseconds: UInt64 = 320) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}
#endif
