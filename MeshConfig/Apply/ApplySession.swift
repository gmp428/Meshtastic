import Foundation

// MARK: - One-radio BLE apply session (sequential fleet; never two at once)

enum ApplySessionState: Equatable, Sendable {
    case idle
    case scanning
    case connecting
    case handshaking          // wantConfig + drain FromRadio + seed session_passkey
    case ensuringPSK
    case applying(ApplySection)
    case waitingReboot(ApplySection)
    case reconnecting(after: ApplySection)
    case verifying
    case succeeded
    /// Indirect: ApplyFailure stores the stage, so this case makes the type recursive.
    indirect case failed(ApplyFailure)
    case disconnecting
    case disconnected
}

enum ApplySection: String, Codable, CaseIterable, Sendable {
    case lora, device, position, display, channel

    var expectsReboot: Bool {
        switch self {
        case .lora, .device, .position, .display: return true
        case .channel: return false
        }
    }

    var displayName: String {
        switch self {
        case .lora: return "LoRa"
        case .device: return "Device"
        case .position: return "Position"
        case .display: return "Display"
        case .channel: return "Channel"
        }
    }

    var progressTitle: String {
        switch self {
        case .lora: return "LoRa"
        case .device: return "Device role + rebroadcast"
        case .position: return "Position"
        case .display: return "Display"
        case .channel: return "Channel Send"
        }
    }
}

struct ApplyFailure: Error, Equatable, Sendable {
    var stage: ApplySessionState
    var message: String
    /// Failed acceptance check ids (no secrets).
    var failedChecks: [String]
}

struct ApplySessionConfig: Sendable {
    var connectTimeout: TimeInterval = 15
    var writeAckTimeout: TimeInterval = 10
    var rebootGrace: TimeInterval = 20
    var reconnectTimeout: TimeInterval = 30
    /// Default order: reboot sections first, channel last (Send, no reboot), then verify.
    var sectionOrder: [ApplySection] = [.lora, .device, .position, .display, .channel]
}

/// Orchestrates scan → connect → handshake → ensure PSK → apply → verify → disconnect.
/// BLE transport is injected (CoreBluetooth + Meshtastic protobuf); this type owns policy.
@MainActor
final class ApplySession: ObservableObject {
    @Published private(set) var state: ApplySessionState = .idle
    @Published private(set) var progressIndex: Int = 0
    @Published private(set) var lastChecklist: [(id: String, label: String, ok: Bool)] = []

    let profile: FleetProfile
    let role: DeviceRole
    let config: ApplySessionConfig

    /// Section that triggered the reboot we are reconnecting after.
    /// `onConnected` moves `.reconnecting` to `.handshaking`, so the origin has to be stored
    /// or the next handshake would start the profile over from LoRa.
    private var rebootResumeSection: ApplySection?

    private var sections: [ApplySection] { config.sectionOrder }

    var orderedSections: [ApplySection] { sections }

    init(profile: FleetProfile, role: DeviceRole, config: ApplySessionConfig = .init()) {
        self.profile = profile
        self.role = role
        self.config = config
    }

    /// Hard gate: fleet UI must not start another session until this is true.
    var canStartAnotherRadio: Bool {
        switch state {
        case .idle, .disconnected, .succeeded, .failed: return true
        default: return false
        }
    }

    /// Stricter gate used by the Apply tab: the next radio waits until disconnect finishes.
    var isReadyForNextRadio: Bool {
        switch state {
        case .idle, .disconnected: return true
        default: return false
        }
    }

    // MARK: Public API (UI calls)

    func startScan() {
        guard state == .idle || state == .disconnected || isTerminal else { return }
        state = .scanning
    }

    /// Call when user picks a peripheral from the scan list.
    func userSelectedPeripheral() {
        guard state == .scanning else { return }
        state = .connecting
    }

    /// Transport reports GATT up; begin PhoneAPI handshake.
    func onConnected() {
        guard state == .connecting || isReconnecting else { return }
        if case .connecting = state {
            rebootResumeSection = nil
        }
        state = .handshaking
    }

    /// After wantConfig drain + session_passkey seeded.
    func onHandshakeComplete() async {
        guard state == .handshaking else { return }
        if let after = rebootResumeSection {
            // Resume next section after the one that rebooted.
            rebootResumeSection = nil
            await advanceAfterReboot(from: after)
            return
        }
        state = .ensuringPSK
        do {
            var mutable = profile
            try FleetPSKStore.ensurePSK(for: &mutable)
            // Persist updated pskRef via profile store before the session starts.
            // Account is `fleet-psk.<profileUUID>`; raw bytes stay in Keychain.
            progressIndex = 0
            try await applyNextSections(from: 0)
        } catch {
            fail(stage: .ensuringPSK, message: "Could not ensure fleet PSK in Keychain.", checks: [])
        }
    }

    func onWriteAcknowledged(section: ApplySection) {
        guard case .applying(let current) = state, current == section else { return }
        if section.expectsReboot {
            state = .waitingReboot(section)
        } else {
            // Channel: no reboot → verify
            state = .verifying
        }
    }

    func onLinkLost() {
        if case .waitingReboot(let section) = state {
            rebootResumeSection = section
            state = .reconnecting(after: section)
            return
        }
        // Unexpected drop mid-apply
        if !isTerminal && state != .disconnecting && state != .disconnected {
            fail(stage: state, message: "BLE link lost unexpectedly.", checks: [])
        }
    }

    func onVerified(snapshot: DeviceSnapshot) {
        guard state == .verifying else { return }
        let results = ProfileAcceptance.evaluate(profile: profile, snap: snapshot, appliedRole: role)
        lastChecklist = results
        if results.allSatisfy(\.ok) {
            state = .succeeded
        } else {
            let failed = results.filter { !$0.ok }.map(\.id)
            fail(stage: .verifying, message: "Read-back did not match profile.", checks: failed)
        }
    }

    /// Transport or UI hard-fail. `message` and `checks` must not contain key material.
    func reportFailure(message: String, checks: [String] = []) {
        guard !isTerminal else { return }
        fail(stage: state, message: message, checks: checks)
    }

    func disconnect() {
        state = .disconnecting
    }

    func onDisconnected() {
        state = .disconnected
    }

    // MARK: Internals

    private var isTerminal: Bool {
        if case .succeeded = state { return true }
        if case .failed = state { return true }
        return false
    }

    private var isReconnecting: Bool {
        if case .reconnecting = state { return true }
        return false
    }

    private func advanceAfterReboot(from section: ApplySection) async {
        guard let idx = sections.firstIndex(of: section) else {
            fail(stage: .waitingReboot(section), message: "Unknown section after reboot.", checks: [])
            return
        }
        let next = idx + 1
        progressIndex = next
        try? await applyNextSections(from: next)
    }

    private func applyNextSections(from index: Int) async throws {
        guard index < sections.count else {
            state = .verifying
            return
        }
        let section = sections[index]
        progressIndex = index
        state = .applying(section)
        // Real app: build AdminMessage set_config / set_channel with session_passkey,
        // wrap PortNum.ADMIN_APP, write ToRadio, wait ack. Channel must Send after set.
        // Transport callback → onWriteAcknowledged(section).
        // ApplyDriver performs that write while state stays `.applying`.
    }

    private func fail(stage: ApplySessionState, message: String, checks: [String]) {
        state = .failed(ApplyFailure(stage: stage, message: message, failedChecks: checks))
    }
}

// MARK: - BLE transport contract (implement with CoreBluetooth + Meshtastic protobufs)

@MainActor
protocol MeshtasticBLETransport: AnyObject {
    /// Scan for Meshtastic service; user picks one peripheral.
    func startScan() async
    func connect(peripheralID: UUID) async throws
    /// Write ToRadio.wantConfigID; drain FromRadio until config complete; seed session_passkey via get_owner.
    func handshake() async throws
    func setLoRa(_ settings: LoRaSettings) async throws
    func setDevice(role: DeviceRole, settings: DeviceSettings) async throws
    func setPosition(_ settings: PositionSettings) async throws
    func setDisplay(_ settings: DisplaySettings) async throws
    /// Replace default primary if needed; write ChannelSettings including 32-byte PSK; Send to device.
    func setPrimaryChannel(_ settings: ChannelSettings, psk: Data) async throws
    func readSnapshot() async throws -> DeviceSnapshot
    func disconnect() async
}

/*
 BLE endpoints (Meshtastic PhoneAPI):
 - ToRadio characteristic  — write wantConfig / MeshPacket admin
 - FromRadio               — read until empty after wantConfig
 - FromNum                 — notify when FromRadio has data

 Admin path: AdminMessage { session_passkey, set_config | set_channel | … }
   → DataMessage portnum = ADMIN_APP → MeshPacket → ToRadio

 After reboot: link drops; full handshake again before next set_*.
 */
