import Foundation

#if DEBUG
/// DEBUG-only apply transport. It does not talk to a radio and it does not log PSK bytes.
/// Scan rows are labeled "(DEBUG)" so they cannot be mistaken for hardware.
///
/// The first sync of a simulated radio differs from the TAK profile and reboots once.
/// A later sync in the same process, with the same profile and no name edits, is already up to date.
@MainActor
final class SimulatedMeshtasticTransport: FleetRadioTransport {
    static let heltecV3 = UUID(uuidString: "A1111111-1111-4111-8111-111111111111")!
    static let t1000e = UUID(uuidString: "A2222222-2222-4222-8222-222222222222")!

    var onDiscovered: (@MainActor (DiscoveredRadio) -> Void)?
    var onBluetoothBlocked: (@MainActor (String?) -> Void)?
    var onUnexpectedLinkLoss: (@MainActor () -> Void)?

    private static var remembered: [UUID: RadioInventory] = [:]

    private var scanTask: Task<Void, Never>?
    private var connectedID: UUID?
    private var inventory: RadioInventory?
    private var expectsDrop = false

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

    func connect(peripheralID: UUID, timeout: TimeInterval) async throws {
        _ = timeout
        guard peripheralID == Self.heltecV3 || peripheralID == Self.t1000e else {
            throw MeshtasticBLEError.notConnected
        }
        try await pause()
        connectedID = peripheralID
    }

    func handshake() async throws {
        guard let connectedID else { throw MeshtasticBLEError.notConnected }
        try await pause(250)
        inventory = Self.remembered[connectedID] ?? Self.factory()
    }

    func radioInventory() -> RadioInventory? {
        inventory
    }

    func applyTransaction(_ writes: [SyncWrite]) async throws {
        guard !writes.isEmpty else { return }
        guard let connectedID, var inventory else { throw MeshtasticBLEError.notConnected }
        try await pause()
        inventory = try inventory.applying(writes)
        self.inventory = inventory
        Self.remembered[connectedID] = inventory
        expectsDrop = true
    }

    func readSnapshot() async throws -> DeviceSnapshot {
        guard let inventory else { throw MeshtasticBLEError.notConnected }
        try await pause(250)
        return try PhoneAPICodec.snapshot(inventory: inventory)
    }

    func disconnect() async {
        stopScan()
        connectedID = nil
        inventory = nil
    }

    func waitForLinkDrop(timeout: TimeInterval) async -> Bool {
        _ = timeout
        guard expectsDrop else { return false }
        try? await Task.sleep(nanoseconds: 450_000_000)
        expectsDrop = false
        connectedID = nil
        return true
    }

    private static func factory() -> RadioInventory {
        let lora = try! PhoneAPICodec.loraConfig(
            merging: Data(),
            settings: LoRaSettings(
                usePreset: true,
                modemPreset: .longFast,
                ignoreMQTT: true,
                frequencySlot: 1,
                region: .us,
                configOkToMQTT: false
            )
        )
        let device = try! PhoneAPICodec.deviceConfig(
            merging: Data(),
            role: .clientBase,
            settings: DeviceSettings(rebroadcastMode: .localOnly, timezone: nil)
        )
        let position = try! PhoneAPICodec.positionConfig(
            merging: Data(),
            settings: PositionSettings(
                smartPosition: false,
                flags: PositionFlagSet(altitude: false, altitudeMSL: true, geoidalSeparation: false),
                gpsMode: .enabled
            )
        )
        let display = try! PhoneAPICodec.displayConfig(
            merging: Data(),
            settings: DisplaySettings(units: .metric)
        )
        let owner = try! PhoneAPICodec.userMessage(merging: Data(), longName: "SimRadio", shortName: "Sim")
        // 0x11 repeated is a stand-in primary key for the simulator, not a fleet key.
        let channel = try! PhoneAPICodec.channelMessage(
            name: "LongFast",
            psk: Data(repeating: 0x11, count: 32),
            uplink: false,
            downlink: false,
            preciseLocation: false,
            channelID: 0x01020304
        )
        let mqtt = try! PhoneAPICodec.mqttConfig(
            merging: Data(),
            enabled: true,
            address: nil,
            username: nil,
            password: nil,
            root: nil,
            clearBridgeFlags: false
        )
        return RadioInventory(
            lora: lora,
            device: device,
            position: position,
            display: display,
            owner: owner,
            longName: "SimRadio",
            shortName: "Sim",
            channels: [channel],
            observedConfigFields: [1, 2, 3, 4, 5, 6, 7, 8],
            observedModuleFields: [1],
            mqtt: mqtt
        )
    }

    private func pause(_ milliseconds: UInt64 = 320) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}
#endif
