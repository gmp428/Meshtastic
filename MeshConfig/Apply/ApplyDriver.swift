import Combine
import Foundation

struct ApplyOutcome: Equatable {
    var passed: Bool
    var deviceName: String
    var peripheralID: UUID?
    var isSimulated: Bool
    var profileName: String
    var profileID: UUID
    var role: DeviceRole
    var longName: String
    var shortName: String
    var checklist: [VerifyCheckResult]
    var message: String
    var failedChecks: [String]
    /// Decoded field lines such as `device.role: TAK_TRACKER → TAK`. No key bytes.
    var fieldDiffs: [String]
}

/// Drives one `ApplySession` against a `FleetRadioTransport`.
/// A second radio cannot start until this session is idle or disconnected.
@MainActor
final class ApplyDriver: ObservableObject {
    @Published private(set) var session: ApplySession?
    @Published private(set) var discovered: [DiscoveredRadio] = []
    @Published private(set) var bluetoothMessage: String?
    @Published private(set) var outcome: ApplyOutcome?
    @Published private(set) var activeRadio: DiscoveredRadio?
    #if DEBUG
    @Published var useSimulation = false
    #endif

    /// Bumped when the session state machine moves so observers refresh.
    @Published private(set) var generation = 0

    private var transport: FleetRadioTransport?
    private var library: FleetLibrary?
    private var roster: DeviceRosterStore?
    private var rosterDeviceID: UUID?
    private var pendingWrites: [SyncWrite] = []
    private var didFinish = false
    private var pumpTask: Task<Void, Never>?
    private var sessionObserver: AnyCancellable?

    var isReadyForNextRadio: Bool {
        session?.isReadyForNextRadio ?? true
    }

    func bind(library: FleetLibrary, roster: DeviceRosterStore) {
        self.library = library
        self.roster = roster
    }

    func beginScan(
        profile: FleetProfile,
        role: DeviceRole,
        names: RadioNames,
        longEdited: Bool,
        shortEdited: Bool,
        rosterDeviceID: UUID?
    ) async throws {
        guard isReadyForNextRadio else { throw MeshApplyPrepError.sessionBusy }
        guard !profile.channel.isDisallowedPrimaryName else {
            throw MeshApplyPrepError.disallowedChannelName
        }

        var prepared = profile
        prepared.channel.name = prepared.channel.name.trimmingCharacters(in: .whitespacesAndNewlines)
        prepared.applyTAKTemplateLocks()
        try FleetPSKStore.ensurePSK(for: &prepared)
        library?.replace(prepared)

        let nextSession = ApplySession(
            profile: prepared,
            role: role,
            names: names,
            longEdited: longEdited,
            shortEdited: shortEdited
        )
        adopt(nextSession)
        discovered = []
        outcome = nil
        activeRadio = nil
        self.rosterDeviceID = rosterDeviceID
        scrubPendingWrites()
        didFinish = false
        bluetoothMessage = nil

        let radioTransport = makeTransport()
        transport = radioTransport
        radioTransport.onDiscovered = { [weak self] radio in
            self?.upsertDiscovered(radio)
        }
        radioTransport.onBluetoothBlocked = { [weak self] message in
            self?.bluetoothMessage = message
        }
        radioTransport.onUnexpectedLinkLoss = { [weak self] in
            self?.session?.onLinkLost()
        }
        nextSession.startScan()
        await radioTransport.startScan()
    }

    func refreshScan() async {
        guard session?.state == .scanning else { return }
        discovered = []
        await transport?.startScan()
    }

    func abortScan() {
        transport?.stopScan()
        guard session?.state == .scanning else { return }
        session?.disconnect()
        session?.onDisconnected()
    }

    /// A scan hit can belong to a roster row the setup screen did not pick first.
    func noteRosterMatch(_ id: UUID) {
        if rosterDeviceID == nil {
            rosterDeviceID = id
        }
    }

    func select(_ radio: DiscoveredRadio) {
        guard session?.state == .scanning else { return }
        activeRadio = radio
        transport?.stopScan()
        session?.userSelectedPeripheral()
        pumpTask?.cancel()
        pumpTask = Task { [weak self] in
            await self?.runSelectedRadio(radio)
        }
    }

    func cancel() async {
        guard !didFinish else { return }
        didFinish = true
        pumpTask?.cancel()
        let radio = activeRadio
        let current = session
        if let current, !isTerminal(current.state) {
            current.reportFailure(message: "cancelled")
        }
        outcome = nil
        scrubPendingWrites()
        if let radio, let current {
            record(
                radio: radio,
                profile: current.profile,
                role: current.role,
                status: .failed,
                names: nil
            )
        }
        await teardownConnection()
    }

    // MARK: - Session pump

    private func runSelectedRadio(_ radio: DiscoveredRadio) async {
        guard let session else { return }
        do {
            try await transport?.connect(peripheralID: radio.peripheralID, timeout: session.config.connectTimeout)
            guard !Task.isCancelled else { return }
            session.onConnected()
            try await transport?.handshake()
            guard !Task.isCancelled else { return }
            await session.onHandshakeComplete()
        } catch is CancellationError {
            return
        } catch {
            session.reportFailure(message: safeMessage(error))
        }
        await pump()
    }

    private func pump() async {
        var spins = 0
        while !Task.isCancelled {
            guard let session else { return }
            switch session.state {
            case .comparing:
                spins = 0
                do {
                    try await publishDiff(session: session)
                } catch is CancellationError {
                    return
                } catch {
                    session.reportFailure(message: safeMessage(error))
                }
            case .applyingChanges:
                spins = 0
                do {
                    guard let transport else { throw MeshtasticBLEError.notConnected }
                    try await transport.applyTransaction(pendingWrites)
                    guard !Task.isCancelled else { return }
                    scrubPendingWrites()
                    session.onChangesCommitted()
                } catch is CancellationError {
                    return
                } catch {
                    scrubPendingWrites()
                    session.reportFailure(message: safeMessage(error))
                }
            case .waitingReboot:
                spins = 0
                let dropped = await transport?.waitForLinkDrop(timeout: session.config.rebootGrace) ?? false
                guard !Task.isCancelled else { return }
                if dropped {
                    session.onLinkLost()
                } else {
                    session.reportFailure(
                        message: "The radio did not drop the link after saving settings. Reboot timed out."
                    )
                }
            case .reconnecting:
                spins = 0
                guard let id = activeRadio?.peripheralID else {
                    session.reportFailure(message: "No radio identifier to reconnect.")
                    continue
                }
                do {
                    try await reconnect(peripheralID: id, session: session)
                } catch is CancellationError {
                    return
                } catch {
                    let waited = Int(session.config.reconnectTimeout.rounded())
                    session.reportFailure(
                        message: "Reconnect after the settings save failed. Waited \(waited) seconds for Bluetooth to return. \(safeMessage(error))"
                    )
                }
            case .verifying:
                spins = 0
                do {
                    guard let snapshot = try await transport?.readSnapshot() else {
                        session.reportFailure(message: "Read-back failed.")
                        continue
                    }
                    guard !Task.isCancelled else { return }
                    session.onVerified(snapshot: snapshot)
                } catch is CancellationError {
                    return
                } catch {
                    session.reportFailure(message: safeMessage(error))
                }
            case .succeeded, .failed:
                await finishSession()
                return
            case .disconnecting:
                await teardownConnection()
                return
            case .connecting, .handshaking, .ensuringPSK:
                spins += 1
                if spins > 40 {
                    session.reportFailure(message: "Apply stalled before the sync could continue.")
                    continue
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            case .idle, .scanning, .disconnected:
                return
            }
        }
    }

    /// After a reboot section, keep connecting until the radio is back and the handshake finishes.
    /// The first CoreBluetooth miss is not fatal: trackers often beep and advertise late.
    /// A handshake that is already running is allowed to finish even if the clock has passed.
    private func reconnect(peripheralID: UUID, session: ApplySession) async throws {
        let deadline = Date().addingTimeInterval(session.config.reconnectTimeout)
        var lastError: Error = MeshtasticBLEError.timedOut
        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            if remaining < 1 {
                throw lastError
            }
            do {
                try await transport?.connect(peripheralID: peripheralID, timeout: remaining)
                guard !Task.isCancelled else { throw CancellationError() }
                session.onConnected()
                try await transport?.handshake()
                guard !Task.isCancelled else { throw CancellationError() }
                await session.onHandshakeComplete()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if !isRetryableReconnect(error) || deadline.timeIntervalSinceNow < 1 {
                    throw error
                }
                session.resumeReconnectWait()
                await transport?.disconnect()
                let pause = min(2.0, deadline.timeIntervalSinceNow)
                if pause > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000))
                }
            }
        }
        throw CancellationError()
    }

    private func isRetryableReconnect(_ error: Error) -> Bool {
        guard let ble = error as? MeshtasticBLEError else { return true }
        switch ble {
        case .timedOut, .notConnected, .serviceNotFound, .bluetoothUnavailable, .adminFailed:
            return true
        case .bluetoothOff, .unauthorized, .cancelled, .invalidPSKLength, .protobufNotIntegrated:
            return false
        }
    }

    private func publishDiff(session: ApplySession) async throws {
        guard let transport else { throw MeshtasticBLEError.notConnected }
        guard let inventory = transport.radioInventory() else {
            throw MeshtasticBLEError.adminFailed("The radio config was not read before the sync.")
        }
        session.noteRadioOwner(longName: inventory.longName, shortName: inventory.shortName)
        var psk = try FleetPSKStore.loadPSKData(for: session.profile.channel.pskRef)
        defer {
            for index in psk.indices {
                psk[index] = 0
            }
        }
        let plan = try SyncDiff.plan(
            inventory: inventory,
            profile: session.profile,
            role: session.role,
            names: session.nameRequest,
            longEdited: session.didEditLongName,
            shortEdited: session.didEditShortName,
            psk: psk
        )
        pendingWrites = plan.writes
        session.adoptPlan(plan)
    }

    private func scrubPendingWrites() {
        pendingWrites = pendingWrites.map { write in
            switch write {
            case .owner(var data):
                zero(&data)
                return .owner(Data())
            case .channel(var data):
                zero(&data)
                return .channel(Data())
            case .config(let kind, var data):
                zero(&data)
                return .config(kind, Data())
            }
        }
        pendingWrites = []
    }

    private func zero(_ data: inout Data) {
        for index in data.indices {
            data[index] = 0
        }
    }

    private func finishSession() async {
        guard !didFinish else { return }
        didFinish = true
        captureOutcome()
        if let outcome, let radio = activeRadio, let session {
            record(
                radio: radio,
                profile: session.profile,
                role: session.role,
                status: outcome.passed ? .configured : .failed,
                names: outcome.passed ? session.namesForRoster : nil
            )
        }
        await teardownConnection()
    }

    private func captureOutcome() {
        guard let session else { return }
        let radio = activeRadio
        switch session.state {
        case .succeeded:
            outcome = ApplyOutcome(
                passed: true,
                deviceName: radio?.name ?? "Radio",
                peripheralID: radio?.peripheralID,
                isSimulated: radio?.isSimulated ?? false,
                profileName: session.profile.name,
                profileID: session.profile.id,
                role: session.role,
                longName: session.resultLongName,
                shortName: session.resultShortName,
                checklist: session.lastChecklist,
                message: "Configured",
                failedChecks: [],
                fieldDiffs: session.syncProgress?.debugLines ?? ["Compare did not finish"]
            )
        case .failed(let failure):
            let failedLabels = session.lastChecklist.filter { failure.failedChecks.contains($0.id) }
            outcome = ApplyOutcome(
                passed: false,
                deviceName: radio?.name ?? "Radio",
                peripheralID: radio?.peripheralID,
                isSimulated: radio?.isSimulated ?? false,
                profileName: session.profile.name,
                profileID: session.profile.id,
                role: session.role,
                longName: session.resultLongName,
                shortName: session.resultShortName,
                checklist: failedLabels.isEmpty ? session.lastChecklist : failedLabels,
                message: failure.message,
                failedChecks: failure.failedChecks,
                fieldDiffs: session.syncProgress?.debugLines ?? ["Compare did not finish"]
            )
        default:
            break
        }
    }

    private func record(
        radio: DiscoveredRadio,
        profile: FleetProfile,
        role: DeviceRole,
        status: DeviceConfigStatus,
        names: RadioNames?
    ) {
        var existingID = rosterDeviceID
        if let candidate = existingID,
           let known = roster?.device(id: candidate)?.peripheralID,
           known != radio.peripheralID {
            // A different radio was chosen than the roster row that opened Apply.
            existingID = nil
        }
        roster?.upsertAttempt(
            existingID: existingID,
            peripheralID: radio.peripheralID,
            displayName: radio.name,
            profileID: profile.id,
            role: role,
            status: status,
            names: names,
            simulatedNote: radio.isSimulated
        )
    }

    private func teardownConnection() async {
        scrubPendingWrites()
        session?.disconnect()
        await transport?.disconnect()
        transport?.stopScan()
        session?.onDisconnected()
        transport = nil
    }

    private func adopt(_ next: ApplySession) {
        session = next
        sessionObserver = next.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.generation &+= 1
            }
        }
    }

    private func upsertDiscovered(_ radio: DiscoveredRadio) {
        if let index = discovered.firstIndex(where: { $0.peripheralID == radio.peripheralID }) {
            discovered[index] = radio
        } else {
            discovered.append(radio)
        }
    }

    private func makeTransport() -> FleetRadioTransport {
        #if DEBUG
        if useSimulation {
            return SimulatedMeshtasticTransport()
        }
        #endif
        return CoreBluetoothMeshtasticTransport()
    }

    private func isTerminal(_ state: ApplySessionState) -> Bool {
        switch state {
        case .succeeded, .failed: return true
        default: return false
        }
    }

    private func safeMessage(_ error: Error) -> String {
        if let ble = error as? MeshtasticBLEError, let text = ble.errorDescription {
            return text
        }
        if let localized = error as? LocalizedError, let text = localized.errorDescription, text.count <= 240 {
            return text
        }
        return "Apply failed."
    }
}

enum MeshApplyPrepError: Error, LocalizedError {
    case disallowedChannelName
    case sessionBusy

    var errorDescription: String? {
        switch self {
        case .disallowedChannelName:
            return "Choose a private channel name. LongFast and ShortFast cannot be the primary."
        case .sessionBusy:
            return "Finish or cancel the current radio before scanning for another."
        }
    }
}
