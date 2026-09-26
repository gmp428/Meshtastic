import CoreBluetooth
import Foundation

/// CoreBluetooth central for the Meshtastic PhoneAPI service.
///
/// Scan, connect, and GATT discovery are real. Mutating admin (`wantConfigID`,
/// `set_config`, `set_channel`, read-back) is not encoded yet, so those methods throw
/// `MeshtasticBLEError.protobufNotIntegrated` instead of reporting a fake success.
///
/// Service and characteristic UUIDs match the public Meshtastic client API:
/// https://meshtastic.org/docs/development/device/client-api/
@MainActor
final class CoreBluetoothMeshtasticTransport: NSObject, FleetRadioTransport {
    static let serviceUUID = CBUUID(string: "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
    static let toRadioUUID = CBUUID(string: "F75C76D2-129E-4DAD-A1DD-7866124401E7")
    static let fromRadioUUID = CBUUID(string: "2C55E69E-4993-11ED-B878-0242AC120002")
    static let fromNumUUID = CBUUID(string: "ED9DA18C-A800-4F66-A670-AA7547E34453")

    var onDiscovered: (@MainActor (DiscoveredRadio) -> Void)?
    var onBluetoothBlocked: (@MainActor (String?) -> Void)?
    var onUnexpectedLinkLoss: (@MainActor () -> Void)?

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var toRadio: CBCharacteristic?
    private var fromRadio: CBCharacteristic?
    private var fromNum: CBCharacteristic?

    private var stateWaiters: [CheckedContinuation<CBManagerState, Never>] = []
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var connectTimeout: Task<Void, Never>?
    private var linkDropContinuation: CheckedContinuation<Bool, Never>?
    private var expectingLinkDrop = false
    private let gate = NSLock()

    func startScan() async {
        let manager = ensureCentral()
        let state = await awaitState(manager)
        switch state {
        case .poweredOn:
            onBluetoothBlocked?(nil)
            manager.scanForPeripherals(
                withServices: [Self.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        case .poweredOff:
            onBluetoothBlocked?("Bluetooth is off. Turn it on, power the radio, and pull to refresh.")
        case .unauthorized:
            onBluetoothBlocked?("Bluetooth permission is off for Mesh Config. Enable it in Settings.")
        default:
            onBluetoothBlocked?("Bluetooth is unavailable.")
        }
    }

    func stopScan() {
        central?.stopScan()
    }

    func connect(peripheralID: UUID) async throws {
        stopScan()
        let manager = ensureCentral()
        let state = await awaitState(manager)
        guard state == .poweredOn else { throw MeshtasticBLEError.bluetoothOff }

        let peripheral = peripherals[peripheralID]
            ?? manager.retrievePeripherals(withIdentifiers: [peripheralID]).first
        guard let peripheral else { throw MeshtasticBLEError.notConnected }
        peripherals[peripheralID] = peripheral
        peripheral.delegate = self

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.storeConnectContinuation(continuation)
                self.armConnectTimeout(manager: manager, peripheral: peripheral)
                manager.connect(peripheral, options: nil)
            }
        } catch {
            connectTimeout?.cancel()
            connectTimeout = nil
            throw error
        }
        connectTimeout?.cancel()
        connectTimeout = nil
    }

    private func armConnectTimeout(manager: CBCentralManager, peripheral: CBPeripheral) {
        connectTimeout?.cancel()
        connectTimeout = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 15_000_000_000)
            } catch {
                return
            }
            self.resumeConnect(.failure(MeshtasticBLEError.timedOut))
            manager.cancelPeripheralConnection(peripheral)
        }
    }

    func handshake() async throws {
        guard connectedPeripheral != nil,
              toRadio != nil,
              fromRadio != nil,
              fromNum != nil else {
            throw MeshtasticBLEError.notConnected
        }
        // GATT is up and FromNum notify was requested. Encoding ToRadio.want_config_id,
        // draining FromRadio, and seeding session_passkey requires Meshtastic protobufs.
        throw MeshtasticBLEError.protobufNotIntegrated(
            "PhoneAPI handshake (wantConfig, FromRadio drain, session passkey)"
        )
    }

    func setLoRa(_ settings: LoRaSettings) async throws {
        try requireLink()
        _ = settings
        throw MeshtasticBLEError.protobufNotIntegrated("LoRa set_config")
    }

    func setDevice(role: DeviceRole, settings: DeviceSettings) async throws {
        try requireLink()
        _ = (role, settings)
        throw MeshtasticBLEError.protobufNotIntegrated("Device set_config")
    }

    func setPosition(_ settings: PositionSettings) async throws {
        try requireLink()
        _ = settings
        throw MeshtasticBLEError.protobufNotIntegrated("Position set_config")
    }

    func setDisplay(_ settings: DisplaySettings) async throws {
        try requireLink()
        _ = settings
        throw MeshtasticBLEError.protobufNotIntegrated("Display set_config")
    }

    func setPrimaryChannel(_ settings: ChannelSettings, psk: Data) async throws {
        try requireLink()
        guard psk.count == 32 else { throw MeshtasticBLEError.invalidPSKLength }
        // Do not log or retain `psk`. Channel replace + Send is protobuf work.
        _ = settings
        throw MeshtasticBLEError.protobufNotIntegrated("Channel set + Send")
    }

    func readSnapshot() async throws -> DeviceSnapshot {
        try requireLink()
        throw MeshtasticBLEError.protobufNotIntegrated("Config read-back")
    }

    func disconnect() async {
        stopScan()
        if let connectedPeripheral, let central {
            central.cancelPeripheralConnection(connectedPeripheral)
        }
        connectedPeripheral = nil
        toRadio = nil
        fromRadio = nil
        fromNum = nil
        resumeLinkDrop(true)
        resumeConnect(.failure(MeshtasticBLEError.cancelled))
    }

    func waitForLinkDrop(timeout: TimeInterval) async -> Bool {
        expectingLinkDrop = true
        defer { expectingLinkDrop = false }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                return await withCheckedContinuation { continuation in
                    self.storeLinkDropContinuation(continuation)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return false
            }
            let next = await group.next()
            let first = next ?? false
            group.cancelAll()
            if !first {
                self.resumeLinkDrop(false)
            }
            return first
        }
    }

    // MARK: - Central lifecycle

    private func ensureCentral() -> CBCentralManager {
        if let central { return central }
        // nil queue: callbacks arrive on the main thread, which matches @MainActor.
        let manager = CBCentralManager(delegate: self, queue: nil)
        central = manager
        return manager
    }

    private func awaitState(_ manager: CBCentralManager) async -> CBManagerState {
        if manager.state != .unknown && manager.state != .resetting {
            return manager.state
        }
        return await withCheckedContinuation { continuation in
            stateWaiters.append(continuation)
        }
    }

    private func requireLink() throws {
        guard connectedPeripheral != nil else { throw MeshtasticBLEError.notConnected }
    }

    private func storeConnectContinuation(_ continuation: CheckedContinuation<Void, Error>) {
        gate.lock()
        connectContinuation = continuation
        gate.unlock()
    }

    private func resumeConnect(_ result: Result<Void, Error>) {
        gate.lock()
        let continuation = connectContinuation
        connectContinuation = nil
        gate.unlock()
        continuation?.resume(with: result)
    }

    private func storeLinkDropContinuation(_ continuation: CheckedContinuation<Bool, Never>) {
        gate.lock()
        linkDropContinuation = continuation
        gate.unlock()
    }

    private func resumeLinkDrop(_ dropped: Bool) {
        gate.lock()
        let continuation = linkDropContinuation
        linkDropContinuation = nil
        gate.unlock()
        continuation?.resume(returning: dropped)
    }

}

extension CoreBluetoothMeshtasticTransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        Task { @MainActor in
            let waiters = self.stateWaiters
            self.stateWaiters.removeAll()
            for waiter in waiters {
                waiter.resume(returning: state)
            }
            if state != .poweredOn {
                central.stopScan()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let id = peripheral.identifier
        let advertised = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = advertised ?? peripheral.name ?? "Meshtastic radio"
        let rssi = RSSI.intValue
        Task { @MainActor in
            self.peripherals[id] = peripheral
            self.onDiscovered?(
                DiscoveredRadio(peripheralID: id, name: name, rssi: rssi, isSimulated: false)
            )
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        Task { @MainActor in
            peripheral.delegate = self
            self.connectedPeripheral = peripheral
            self.peripherals[id] = peripheral
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let message = error?.localizedDescription
        Task { @MainActor in
            self.resumeConnect(.failure(message.map { _ in MeshtasticBLEError.notConnected } ?? .notConnected))
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            let wasCurrent = self.connectedPeripheral?.identifier == peripheral.identifier
            if wasCurrent {
                self.connectedPeripheral = nil
            }
            if self.connectContinuation != nil {
                self.resumeConnect(.failure(MeshtasticBLEError.notConnected))
                return
            }
            if self.expectingLinkDrop {
                self.resumeLinkDrop(true)
            } else if wasCurrent {
                self.onUnexpectedLinkLoss?()
            }
        }
    }
}

extension CoreBluetoothMeshtasticTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if error != nil {
                self.resumeConnect(.failure(MeshtasticBLEError.serviceNotFound))
                return
            }
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                self.resumeConnect(.failure(MeshtasticBLEError.serviceNotFound))
                return
            }
            peripheral.discoverCharacteristics(
                [Self.toRadioUUID, Self.fromRadioUUID, Self.fromNumUUID],
                for: service
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if error != nil {
                self.resumeConnect(.failure(MeshtasticBLEError.serviceNotFound))
                return
            }
            let characteristics = service.characteristics ?? []
            self.toRadio = characteristics.first { $0.uuid == Self.toRadioUUID }
            self.fromRadio = characteristics.first { $0.uuid == Self.fromRadioUUID }
            self.fromNum = characteristics.first { $0.uuid == Self.fromNumUUID }
            guard self.toRadio != nil, self.fromRadio != nil, let fromNum = self.fromNum else {
                self.resumeConnect(.failure(MeshtasticBLEError.serviceNotFound))
                return
            }
            peripheral.setNotifyValue(true, for: fromNum)
            self.resumeConnect(.success(()))
        }
    }
}
