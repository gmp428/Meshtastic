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
    var checklist: [(id: String, label: String, ok: Bool)]
    var message: String
    var failedChecks: [String]
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
    private var ackedSections: Set<ApplySection> = []
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

        let nextSession = ApplySession(profile: prepared, role: role)
        adopt(nextSession)
        discovered = []
        outcome = nil
        activeRadio = nil
        self.rosterDeviceID = rosterDeviceID
        ackedSections = []
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
        if let radio, let current {
            record(
                radio: radio,
                profile: current.profile,
                role: current.role,
                status: .failed
            )
        }
        await teardownConnection()
    }

    // MARK: - Session pump

    private func runSelectedRadio(_ radio: DiscoveredRadio) async {
        guard let session else { return }
        do {
            try await transport?.connect(peripheralID: radio.peripheralID)
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
            case .applying(let section):
                spins = 0
                if ackedSections.contains(section) {
                    session.reportFailure(message: "Apply stalled on \(section.displayName).")
                    continue
                }
                do {
                    try await write(section, session: session)
                    guard !Task.isCancelled else { return }
                    ackedSections.insert(section)
                    session.onWriteAcknowledged(section: section)
                } catch is CancellationError {
                    return
                } catch {
                    session.reportFailure(message: safeMessage(error))
                }
            case .waitingReboot(let section):
                spins = 0
                let dropped = await transport?.waitForLinkDrop(timeout: session.config.rebootGrace) ?? false
                guard !Task.isCancelled else { return }
                if dropped {
                    session.onLinkLost()
                } else {
                    session.reportFailure(
                        message: "The radio did not drop the link after \(section.displayName). Reboot timed out."
                    )
                }
            case .reconnecting(let after):
                spins = 0
                guard let id = activeRadio?.peripheralID else {
                    session.reportFailure(message: "No radio identifier to reconnect.")
                    continue
                }
                do {
                    try await transport?.connect(peripheralID: id)
                    guard !Task.isCancelled else { return }
                    session.onConnected()
                    try await transport?.handshake()
                    guard !Task.isCancelled else { return }
                    await session.onHandshakeComplete()
                } catch is CancellationError {
                    return
                } catch {
                    session.reportFailure(
                        message: "Reconnect after \(after.displayName) failed. \(safeMessage(error))"
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
                    session.reportFailure(message: "Apply stalled before the next config section.")
                    continue
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
            case .idle, .scanning, .disconnected:
                return
            }
        }
    }

    private func write(_ section: ApplySection, session: ApplySession) async throws {
        guard let transport else { throw MeshtasticBLEError.notConnected }
        let profile = session.profile
        switch section {
        case .lora:
            try await transport.setLoRa(profile.lora)
        case .device:
            try await transport.setDevice(role: session.role, settings: profile.device)
        case .position:
            try await transport.setPosition(profile.position)
        case .display:
            try await transport.setDisplay(profile.display)
        case .channel:
            // Missing Keychain key fails here, before any channel write.
            var psk = try FleetPSKStore.loadPSKData(for: profile.channel.pskRef)
            defer {
                for index in psk.indices {
                    psk[index] = 0
                }
            }
            try await transport.setPrimaryChannel(profile.channel, psk: psk)
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
                status: outcome.passed ? .configured : .failed
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
                checklist: session.lastChecklist,
                message: "Configured",
                failedChecks: []
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
                checklist: failedLabels.isEmpty ? session.lastChecklist : failedLabels,
                message: failure.message,
                failedChecks: failure.failedChecks
            )
        default:
            break
        }
    }

    private func record(
        radio: DiscoveredRadio,
        profile: FleetProfile,
        role: DeviceRole,
        status: DeviceConfigStatus
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
            simulatedNote: radio.isSimulated
        )
    }

    private func teardownConnection() async {
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
