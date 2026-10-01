import CoreBluetooth
import Foundation

/// CoreBluetooth central for the Meshtastic PhoneAPI service.
///
/// Scan and GATT are real. Handshake reads the full config, then one edit transaction
/// writes only the fields that differ. The DEBUG simulated transport is a separate type.
///
/// Service and characteristic UUIDs match the public Meshtastic client API:
/// https://meshtastic.org/docs/development/device/client-api/
@MainActor
final class CoreBluetoothMeshtasticTransport: NSObject, FleetRadioTransport {
    nonisolated static let serviceUUID = CBUUID(string: "6BA1B218-15A8-461F-9FA8-5DCAE273EAFD")
    nonisolated static let toRadioUUID = CBUUID(string: "F75C76D2-129E-4DAD-A1DD-7866124401E7")
    nonisolated static let fromRadioUUID = CBUUID(string: "2C55E69E-4993-11ED-B878-0242AC120002")
    nonisolated static let fromNumUUID = CBUUID(string: "ED9DA18C-A800-4F66-A670-AA7547E34453")

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
    private var readContinuation: CheckedContinuation<Data, Error>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var fromNumWaiters: [CheckedContinuation<Void, Never>] = []
    private var notifyWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingReads: [Data] = []
    private var fromNumPending = false
    private var fromNumNotifyReady = false
    private var sawLinkDrop = false
    private var adminExpectsReboot = false
    private var lastNotice: String?
    private var packetCounter = UInt32.random(in: 1...0x00FF_FFFF)
    private var sessionPasskey = Data()
    private var nodeNum: UInt32?
    private var loraConfig: Data?
    private var deviceConfig: Data?
    private var positionConfig: Data?
    private var displayConfig: Data?
    private var networkConfig: Data?
    /// MQTT module body from the handshake. May contain the MQTT password. Scrubbed with the session.
    private var mqttConfig: Data?
    /// Last `User` body from get_owner. Merged into set_owner so id, keys, and license flags stay put.
    private var ownerUser: Data?
    private var capturedChannels: [Data] = []
    private var observedConfigFields: Set<Int> = []
    private var observedModuleFields: Set<Int> = []
    private var inventory: RadioInventory?
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

    func connect(peripheralID: UUID, timeout: TimeInterval) async throws {
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
                self.armConnectTimeout(manager: manager, peripheral: peripheral, timeout: timeout)
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

    private func armConnectTimeout(manager: CBCentralManager, peripheral: CBPeripheral, timeout: TimeInterval) {
        connectTimeout?.cancel()
        let nanos = UInt64(max(timeout, 1) * 1_000_000_000)
        connectTimeout = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return
            }
            self.resumeConnect(.failure(MeshtasticBLEError.timedOut))
            manager.cancelPeripheralConnection(peripheral)
        }
    }

    func handshake() async throws {
        guard PhoneAPICodec.selfCheck() else {
            throw MeshtasticBLEError.adminFailed(
                "PhoneAPI encoder self-check failed. This build will not write to the radio."
            )
        }
        if let problem = SyncDiff.selfCheck() {
            throw MeshtasticBLEError.adminFailed(
                "Sync diff self-check failed (\(problem)). This build will not write to the radio."
            )
        }
        guard connectedPeripheral != nil, toRadio != nil, fromRadio != nil, fromNum != nil else {
            throw MeshtasticBLEError.notConnected
        }
        scrubSession()
        sawLinkDrop = false
        lastNotice = nil
        await waitForNotifyReady()
        try await discardQueuedPackets()
        // 69420 asks current firmware for config and channels without the node database.
        let nonce = PhoneAPICodec.configOnlyNonce
        try await writeWithRetry(PhoneAPICodec.wantConfig(nonce: nonce))

        let deadline = Date().addingTimeInterval(45)
        var sawMyNode = false
        var sawComplete = false
        while Date() < deadline && !sawComplete {
            if sawLinkDrop { throw MeshtasticBLEError.notConnected }
            let frame = try await readNextFrame(until: deadline)
            switch try PhoneAPICodec.classify(frame) {
            case .myNode(let num) where num != 0:
                nodeNum = num
                sawMyNode = true
            case .config(let slice):
                store(slice)
                sawMyNode = true
            case .otherConfig(let field):
                observedConfigFields.insert(field)
            case .moduleConfig(let field, let mqtt):
                observedModuleFields.insert(field)
                if field == 1, let mqtt {
                    mqttConfig = mqtt
                }
            case .channel(let channel):
                capturedChannels.append(channel.raw)
            case .configComplete(let id) where id == nonce && sawMyNode:
                sawComplete = true
            case .notice(let text):
                lastNotice = text
            default:
                break
            }
        }
        guard sawComplete else {
            throw MeshtasticBLEError.adminFailed(noticeSuffix("The radio did not finish sending its config."))
        }
        guard let nodeNum, nodeNum != 0 else {
            throw MeshtasticBLEError.adminFailed("The radio did not report its node number.")
        }
        _ = nodeNum
        guard loraConfig != nil, deviceConfig != nil, positionConfig != nil, displayConfig != nil else {
            throw MeshtasticBLEError.adminFailed(
                "Handshake did not include LoRa, device, position, and display config. Mesh Config will not send a partial config."
            )
        }
        let owner = try await roundTrip(
            admin: PhoneAPICodec.getOwnerAdmin(),
            wantResponse: true,
            wantBody: true,
            linkDropSucceeds: false
        )
        if let key = owner?.passkey, key.count == 8 {
            adoptPasskey(key)
        }
        guard let user = owner?.owner, !user.isEmpty else {
            throw MeshtasticBLEError.adminFailed("The radio did not return its owner record.")
        }
        ownerUser = user
        guard sessionPasskey.count == 8 else {
            throw MeshtasticBLEError.adminFailed("The radio did not return an admin session passkey.")
        }
        guard let loraConfig, let deviceConfig, let positionConfig, let displayConfig else {
            throw MeshtasticBLEError.adminFailed(
                "Handshake did not include LoRa, device, position, and display config. Mesh Config will not send a partial config."
            )
        }
        inventory = RadioInventory(
            lora: loraConfig,
            device: deviceConfig,
            position: positionConfig,
            display: displayConfig,
            owner: user,
            longName: try PhoneAPICodec.longName(from: user),
            shortName: try PhoneAPICodec.shortName(from: user),
            channels: capturedChannels,
            observedConfigFields: observedConfigFields,
            observedModuleFields: observedModuleFields,
            network: networkConfig ?? Data(),
            mqtt: mqttConfig ?? Data()
        )
    }

    func radioInventory() -> RadioInventory? {
        inventory
    }

    func applyTransaction(_ writes: [SyncWrite]) async throws {
        guard !writes.isEmpty else { return }
        try requireLink()
        guard sessionPasskey.count == 8 else {
            throw MeshtasticBLEError.adminFailed("The admin session is missing. Reconnect and try this radio again.")
        }
        // commit_edit_settings disables Bluetooth. A drop before that commit is a failed sync.
        adminExpectsReboot = true
        defer { adminExpectsReboot = false }
        var didCommit = false
        do {
            _ = try await roundTrip(
                admin: PhoneAPICodec.beginEditAdmin(passkey: sessionPasskey),
                wantResponse: true,
                wantBody: false,
                linkDropSucceeds: false
            )
            for write in writes {
                if linkDropped {
                    throw MeshtasticBLEError.adminFailed(
                        "The radio dropped the Bluetooth link before the settings were committed."
                    )
                }
                try await send(write)
            }
            didCommit = true
            _ = try await roundTrip(
                admin: PhoneAPICodec.commitEditAdmin(passkey: sessionPasskey),
                wantResponse: true,
                wantBody: false,
                linkDropSucceeds: true
            )
            if linkDropped { return }
            _ = try await roundTrip(
                admin: PhoneAPICodec.rebootAdmin(
                    seconds: PhoneAPICodec.rebootDelaySeconds,
                    passkey: sessionPasskey
                ),
                wantResponse: true,
                wantBody: false,
                linkDropSucceeds: true
            )
        } catch {
            if didCommit && linkDropped { return }
            throw mapCodec(error)
        }
    }

    func readSnapshot() async throws -> DeviceSnapshot {
        try requireLink()
        let lora = try await fetchConfig(.lora)
        let device = try await fetchConfig(.device)
        let position = try await fetchConfig(.position)
        let channel = try await fetchChannel()
        let owner = try await fetchOwner()
        let network = try await fetchConfig(.network)
        let mqtt = try await fetchMQTT()
        return try PhoneAPICodec.snapshot(
            lora: lora,
            device: device,
            position: position,
            channel: channel,
            owner: owner,
            network: network,
            mqtt: mqtt
        )
    }

    func disconnect() async {
        stopScan()
        if let connectedPeripheral, let central {
            central.cancelPeripheralConnection(connectedPeripheral)
        }
        tearDownLink()
        resumeLinkDrop(true)
        resumeConnect(.failure(MeshtasticBLEError.cancelled))
        failPendingIO(MeshtasticBLEError.cancelled)
    }

    func waitForLinkDrop(timeout: TimeInterval) async -> Bool {
        if sawLinkDrop || connectedPeripheral == nil {
            sawLinkDrop = false
            return true
        }
        expectingLinkDrop = true
        defer { expectingLinkDrop = false }
        let dropped = await withTaskGroup(of: Bool.self) { group in
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
        sawLinkDrop = false
        return dropped
    }

    // MARK: - Admin session

    private var linkDropped: Bool { sawLinkDrop || connectedPeripheral == nil }

    /// Writes inside the open edit transaction. A link drop here is a failure, not a reboot.
    private func send(_ write: SyncWrite) async throws {
        let admin: Data
        switch write {
        case .owner(let user):
            admin = PhoneAPICodec.setOwnerAdmin(user: user, passkey: sessionPasskey)
        case .config(let kind, let body):
            admin = PhoneAPICodec.setConfigAdmin(
                config: PhoneAPICodec.configWrapper(kind: kind, body: body),
                passkey: sessionPasskey
            )
        case .channel(let channel):
            admin = PhoneAPICodec.setChannelAdmin(channel: channel, passkey: sessionPasskey)
        case .moduleMQTT(let body):
            admin = PhoneAPICodec.setModuleConfigAdmin(
                module: PhoneAPICodec.mqttModuleWrapper(body),
                passkey: sessionPasskey
            )
        }
        do {
            _ = try await roundTrip(
                admin: admin,
                wantResponse: true,
                wantBody: false,
                linkDropSucceeds: false
            )
        } catch MeshtasticBLEError.notConnected {
            throw MeshtasticBLEError.adminFailed(
                "The radio dropped the Bluetooth link before the settings were committed."
            )
        }
    }

    private func fetchConfig(_ kind: PhoneAPICodec.ConfigKind) async throws -> Data {
        let type: UInt64
        let label: String
        switch kind {
        case .device:
            type = 0
            label = "device"
        case .position:
            type = 1
            label = "position"
        case .display:
            type = 4
            label = "display"
        case .lora:
            type = 5
            label = "LoRa"
        case .network:
            type = 3
            label = "network"
        }
        let admin = PhoneAPICodec.getConfigAdmin(kind: type, passkey: sessionPasskey)
        guard let message = try await roundTrip(
            admin: admin,
            wantResponse: true,
            wantBody: true,
            linkDropSucceeds: false
        ),
              let config = message.config,
              config.kind == kind else {
            throw MeshtasticBLEError.adminFailed("The radio did not return \(label) config.")
        }
        return config.body
    }

    private func fetchOwner() async throws -> Data {
        let admin = PhoneAPICodec.getOwnerAdmin(passkey: sessionPasskey)
        guard let message = try await roundTrip(
            admin: admin,
            wantResponse: true,
            wantBody: true,
            linkDropSucceeds: false
        ),
              let owner = message.owner else {
            throw MeshtasticBLEError.adminFailed("The radio did not return its long name.")
        }
        return owner
    }

    private func fetchChannel() async throws -> PhoneAPICodec.ParsedChannel {
        let admin = PhoneAPICodec.getChannelAdmin(index: 0, passkey: sessionPasskey)
        guard let message = try await roundTrip(
            admin: admin,
            wantResponse: true,
            wantBody: true,
            linkDropSucceeds: false
        ),
              let channel = message.channel else {
            throw MeshtasticBLEError.adminFailed("The radio did not return the primary channel.")
        }
        return channel
    }

    private func roundTrip(
        admin: Data,
        wantResponse: Bool,
        wantBody: Bool,
        linkDropSucceeds: Bool
    ) async throws -> PhoneAPICodec.ParsedAdmin? {
        guard let nodeNum, nodeNum != 0 else {
            throw MeshtasticBLEError.adminFailed("The radio did not report a node number.")
        }
        let packetID = nextPacketID()
        let frame = PhoneAPICodec.toRadioPacket(
            to: nodeNum,
            packetID: packetID,
            admin: admin,
            wantResponse: wantResponse
        )
        try await writeWithRetry(frame)
        return try await waitForAdmin(
            packetID: packetID,
            wantBody: wantBody,
            linkDropSucceeds: linkDropSucceeds,
            timeout: 10
        )
    }

    private func waitForAdmin(
        packetID: UInt32,
        wantBody: Bool,
        linkDropSucceeds: Bool,
        timeout: TimeInterval
    ) async throws -> PhoneAPICodec.ParsedAdmin? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if sawLinkDrop {
                if linkDropSucceeds { return nil }
                throw MeshtasticBLEError.adminFailed("The radio dropped the Bluetooth link during the admin write.")
            }
            let frame: Data
            do {
                frame = try await readNextFrame(until: deadline)
            } catch {
                if sawLinkDrop && linkDropSucceeds { return nil }
                throw error
            }
            switch try PhoneAPICodec.classify(frame) {
            case .notice(let text):
                lastNotice = text
            case .routing(let requestID, let code) where requestID == packetID:
                if let code, code != 0 {
                    throw MeshtasticBLEError.adminFailed(PhoneAPICodec.routingFailureText(code))
                }
                if !wantBody { return nil }
            case .admin(let requestID, let message) where requestID == packetID:
                if let key = message.passkey, key.count == 8 {
                    adoptPasskey(key)
                }
                if wantBody && message.config == nil && message.channel == nil && message.owner == nil && message.mqtt == nil && message.passkey == nil {
                    continue
                }
                return message
            default:
                break
            }
        }
        if sawLinkDrop && linkDropSucceeds { return nil }
        throw MeshtasticBLEError.adminFailed(noticeSuffix("The radio did not acknowledge the admin write before the timeout."))
    }

    private func store(_ slice: PhoneAPICodec.ConfigSlice) {
        switch slice.kind {
        case .lora:
            loraConfig = slice.body
            observedConfigFields.insert(6)
        case .device:
            deviceConfig = slice.body
            observedConfigFields.insert(1)
        case .position:
            positionConfig = slice.body
            observedConfigFields.insert(2)
        case .display:
            displayConfig = slice.body
            observedConfigFields.insert(5)
        case .network:
            networkConfig = slice.body
            observedConfigFields.insert(4)
        }
    }

    private func fetchMQTT() async throws -> Data {
        let admin = PhoneAPICodec.getModuleConfigAdmin(kind: 0, passkey: sessionPasskey)
        guard let message = try await roundTrip(
            admin: admin,
            wantResponse: true,
            wantBody: true,
            linkDropSucceeds: false
        ),
              let mqtt = message.mqtt else {
            throw MeshtasticBLEError.adminFailed("The radio did not return MQTT module config.")
        }
        return mqtt
    }

    private func nextPacketID() -> UInt32 {
        packetCounter &+= 1
        if packetCounter == 0
            || packetCounter == PhoneAPICodec.configOnlyNonce
            || packetCounter == PhoneAPICodec.nodesOnlyNonce {
            packetCounter = 1
        }
        return packetCounter
    }

    private func adoptPasskey(_ key: Data) {
        guard key.count == 8 else { return }
        scrubPasskey()
        sessionPasskey = key
    }

    private func scrubPasskey() {
        for index in sessionPasskey.indices {
            sessionPasskey[index] = 0
        }
        sessionPasskey = Data()
    }

    private func scrubSession() {
        scrubPasskey()
        nodeNum = nil
        loraConfig = nil
        deviceConfig = nil
        positionConfig = nil
        displayConfig = nil
        if networkConfig != nil {
            for index in networkConfig!.indices {
                networkConfig![index] = 0
            }
            networkConfig = nil
        }
        if mqttConfig != nil {
            for index in mqttConfig!.indices {
                mqttConfig![index] = 0
            }
            mqttConfig = nil
        }
        observedConfigFields = []
        observedModuleFields = []
        for channelIndex in capturedChannels.indices {
            for byteIndex in capturedChannels[channelIndex].indices {
                capturedChannels[channelIndex][byteIndex] = 0
            }
        }
        capturedChannels = []
        if inventory != nil {
            for byteIndex in inventory!.owner.indices {
                inventory!.owner[byteIndex] = 0
            }
            for channelIndex in inventory!.channels.indices {
                for byteIndex in inventory!.channels[channelIndex].indices {
                    inventory!.channels[channelIndex][byteIndex] = 0
                }
            }
            for index in inventory!.network.indices {
                inventory!.network[index] = 0
            }
            for index in inventory!.mqtt.indices {
                inventory!.mqtt[index] = 0
            }
            inventory = nil
        }
        if ownerUser != nil {
            for index in ownerUser!.indices {
                ownerUser![index] = 0
            }
            ownerUser = nil
        }
    }

    private func noticeSuffix(_ message: String) -> String {
        guard let lastNotice, !lastNotice.isEmpty else { return message }
        return "\(message) \(lastNotice)"
    }

    private func mapCodec(_ error: Error) -> Error {
        if error is PhoneAPICodec.CodecError {
            return MeshtasticBLEError.adminFailed("Mesh Config could not encode the admin message.")
        }
        return error
    }

    // MARK: - FromRadio drain

    private func discardQueuedPackets() async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            do {
                let data = try await readOnce(timeout: 2)
                if data.isEmpty {
                    if fromNumPending {
                        fromNumPending = false
                        continue
                    }
                    return
                }
            } catch MeshtasticBLEError.timedOut {
                if let queued = popPending(), !queued.isEmpty {
                    continue
                }
                return
            }
        }
        throw MeshtasticBLEError.timedOut
    }

    private func readNextFrame(until deadline: Date) async throws -> Data {
        while Date() < deadline {
            if sawLinkDrop { throw MeshtasticBLEError.notConnected }
            do {
                let slice = min(8.0, max(0.2, deadline.timeIntervalSinceNow))
                let data = try await readOnce(timeout: slice)
                if !data.isEmpty { return data }
                if fromNumPending {
                    fromNumPending = false
                    continue
                }
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { break }
                _ = await waitForFromNum(timeout: min(1.5, remaining))
            } catch MeshtasticBLEError.timedOut {
                if let queued = popPending(), !queued.isEmpty { return queued }
                if Date() >= deadline { throw MeshtasticBLEError.timedOut }
            }
        }
        if let queued = popPending(), !queued.isEmpty { return queued }
        throw MeshtasticBLEError.timedOut
    }

    private func readOnce(timeout: TimeInterval) async throws -> Data {
        if let queued = popPending() { return queued }
        guard let connected = connectedPeripheral, let fromRadio else { throw MeshtasticBLEError.notConnected }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                    self.storeRead(continuation)
                    connected.readValue(for: fromRadio)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(timeout, 0.05) * 1_000_000_000))
                await self.failRead(MeshtasticBLEError.timedOut)
                throw MeshtasticBLEError.timedOut
            }
            let next = try await group.next()
            group.cancelAll()
            guard let next else { throw MeshtasticBLEError.timedOut }
            return next
        }
    }

    private func waitForFromNum(timeout: TimeInterval) async -> Bool {
        if fromNumPending { return true }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    if self.fromNumPending {
                        continuation.resume()
                    } else {
                        self.fromNumWaiters.append(continuation)
                    }
                }
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(timeout, 0.05) * 1_000_000_000))
                return false
            }
            let woke = await group.next() ?? false
            group.cancelAll()
            if !woke {
                self.resumeFromNumWaiters()
            }
            return woke || self.fromNumPending
        }
    }

    private func waitForNotifyReady() async {
        if fromNumNotifyReady { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                await withCheckedContinuation { continuation in
                    if self.fromNumNotifyReady {
                        continuation.resume()
                    } else {
                        self.notifyWaiters.append(continuation)
                    }
                }
            }
            group.addTask { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.resumeNotifyWaiters()
            }
            await group.next()
            group.cancelAll()
        }
    }

    private func writeWithRetry(_ data: Data) async throws {
        var attempt = 0
        while true {
            do {
                try await writeOnce(data)
                return
            } catch let error as CBATTError where error.code == .insufficientResources && attempt < 3 {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(attempt * 120_000_000))
            }
        }
    }

    private func writeOnce(_ data: Data) async throws {
        guard let connected = connectedPeripheral, let toRadio else { throw MeshtasticBLEError.notConnected }
        guard toRadio.properties.contains(.write) || toRadio.properties.contains(.writeWithoutResponse) else {
            throw MeshtasticBLEError.adminFailed("The radio did not offer a writable ToRadio characteristic.")
        }
        if toRadio.properties.contains(.write) {
            let limit = connected.maximumWriteValueLength(for: .withResponse)
            if limit > 0 && data.count > limit {
                throw MeshtasticBLEError.adminFailed(
                    "The admin message is larger than this radio's Bluetooth write limit."
                )
            }
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        self.storeWrite(continuation)
                        connected.writeValue(data, for: toRadio, type: .withResponse)
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 8_000_000_000)
                    await self.failWrite(MeshtasticBLEError.timedOut)
                    throw MeshtasticBLEError.timedOut
                }
                try await group.next()
                group.cancelAll()
            }
            return
        }
        connected.writeValue(data, for: toRadio, type: .withoutResponse)
    }

    private func popPending() -> Data? {
        guard !pendingReads.isEmpty else { return nil }
        return pendingReads.removeFirst()
    }

    private func failRead(_ error: Error) {
        _ = resumeRead(.failure(error))
    }

    private func failWrite(_ error: Error) {
        _ = resumeWrite(.failure(error))
    }

    private func failPendingIO(_ error: Error) {
        failRead(error)
        failWrite(error)
        resumeFromNumWaiters()
        resumeNotifyWaiters()
    }

    private func tearDownLink() {
        connectedPeripheral = nil
        toRadio = nil
        fromRadio = nil
        fromNum = nil
        fromNumNotifyReady = false
        fromNumPending = false
        pendingReads.removeAll()
        scrubSession()
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

    private func storeRead(_ continuation: CheckedContinuation<Data, Error>) {
        gate.lock()
        let previous = readContinuation
        readContinuation = continuation
        gate.unlock()
        previous?.resume(throwing: MeshtasticBLEError.cancelled)
    }

    private func resumeRead(_ result: Result<Data, Error>) -> Bool {
        gate.lock()
        let continuation = readContinuation
        readContinuation = nil
        gate.unlock()
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }

    private func storeWrite(_ continuation: CheckedContinuation<Void, Error>) {
        gate.lock()
        let previous = writeContinuation
        writeContinuation = continuation
        gate.unlock()
        previous?.resume(throwing: MeshtasticBLEError.cancelled)
    }

    private func resumeWrite(_ result: Result<Void, Error>) -> Bool {
        gate.lock()
        let continuation = writeContinuation
        writeContinuation = nil
        gate.unlock()
        guard let continuation else { return false }
        continuation.resume(with: result)
        return true
    }

    private func resumeFromNumWaiters() {
        let waiters = fromNumWaiters
        fromNumWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeNotifyWaiters() {
        let waiters = notifyWaiters
        notifyWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
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
        Task { @MainActor in
            self.resumeConnect(.failure(MeshtasticBLEError.notConnected))
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
                self.sawLinkDrop = true
                self.tearDownLink()
            }
            if self.connectContinuation != nil {
                self.resumeConnect(.failure(MeshtasticBLEError.notConnected))
                return
            }
            self.failPendingIO(MeshtasticBLEError.notConnected)
            if self.expectingLinkDrop || self.adminExpectsReboot {
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

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.fromNumUUID else { return }
        Task { @MainActor in
            self.fromNumNotifyReady = error == nil
            self.resumeNotifyWaiters()
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        let uuid = characteristic.uuid
        let value = characteristic.value ?? Data()
        Task { @MainActor in
            if uuid == Self.fromNumUUID {
                self.fromNumPending = true
                self.resumeFromNumWaiters()
                return
            }
            guard uuid == Self.fromRadioUUID else { return }
            if let error {
                if !self.resumeRead(.failure(error)) {
                    self.pendingReads.append(Data())
                }
                return
            }
            if !self.resumeRead(.success(value)) {
                self.pendingReads.append(value)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.toRadioUUID else { return }
        Task { @MainActor in
            if let error {
                _ = self.resumeWrite(.failure(error))
            } else {
                _ = self.resumeWrite(.success(()))
            }
        }
    }
}
