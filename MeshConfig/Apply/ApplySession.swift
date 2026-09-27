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
    case owner, lora, device, position, display, channel

    var expectsReboot: Bool {
        switch self {
        case .owner, .lora, .device, .position, .display: return true
        case .channel: return false
        }
    }

    var displayName: String {
        switch self {
        case .owner: return "Name"
        case .lora: return "LoRa"
        case .device: return "Device"
        case .position: return "Position"
        case .display: return "Display"
        case .channel: return "Channel"
        }
    }

    var progressTitle: String {
        switch self {
        case .owner: return "TAK long name"
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
    /// First connect, while the radio is already on and advertising.
    var connectTimeout: TimeInterval = 15
    var writeAckTimeout: TimeInterval = 10
    /// How long to wait for Bluetooth to drop after a reboot section.
    /// Trackers such as the T1000-E beep and reboot well after a 20s grace.
    var rebootGrace: TimeInterval = 60
    /// How long to keep trying Bluetooth after that drop, including a slow boot.
    /// A single missed connect does not end the wait.
    var reconnectTimeout: TimeInterval = 90
    /// Default order: name, then reboot sections, channel last (Send, no reboot), then verify.
    var sectionOrder: [ApplySection] = [.owner, .lora, .device, .position, .display, .channel]
}

/// Orchestrates scan → connect → handshake → ensure PSK → apply → verify → disconnect.
/// BLE transport is injected (CoreBluetooth + Meshtastic protobuf); this type owns policy.
@MainActor
final class ApplySession: ObservableObject {
    @Published private(set) var state: ApplySessionState = .idle
    @Published private(set) var progressIndex: Int = 0
    @Published private(set) var lastChecklist: [VerifyCheckResult] = []

    let profile: FleetProfile
    let role: DeviceRole
    /// Meshtastic long name for this radio. TAK shows this as the callsign.
    let longName: String
    /// Meshtastic short name for this radio. The 4-character mesh badge.
    let shortName: String
    let config: ApplySessionConfig

    /// Section that triggered the reboot we are reconnecting after.
    /// `onConnected` moves `.reconnecting` to `.handshaking`, so the origin has to be stored
    /// or the next handshake would start the profile over from LoRa.
    private var rebootResumeSection: ApplySection?

    private var sections: [ApplySection] { config.sectionOrder }

    var orderedSections: [ApplySection] { sections }

    init(
        profile: FleetProfile,
        role: DeviceRole,
        names: RadioNames,
        config: ApplySessionConfig = .init()
    ) {
        self.profile = profile
        self.role = role
        self.longName = names.longName
        self.shortName = names.shortName
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
        // The radio can drop again while it is still booting. That is part of the reconnect,
        // not a failed session, until the next handshake finishes.
        if let section = rebootResumeSection {
            switch state {
            case .handshaking, .reconnecting:
                state = .reconnecting(after: section)
                return
            default:
                break
            }
        }
        // Unexpected drop mid-apply
        if !isTerminal && state != .disconnecting && state != .disconnected {
            fail(stage: state, message: "BLE link lost unexpectedly.", checks: [])
        }
    }

    /// Handshake failed before the post-reboot window ended. Stay on this section and try again.
    func resumeReconnectWait() {
        guard let section = rebootResumeSection else { return }
        if case .handshaking = state {
            state = .reconnecting(after: section)
        }
    }

    func onVerified(snapshot: DeviceSnapshot) {
        guard state == .verifying else { return }
        let results = ProfileAcceptance.evaluate(
            profile: profile,
            snap: snapshot,
            appliedRole: role,
            appliedLongName: longName
        )
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
    func connect(peripheralID: UUID, timeout: TimeInterval) async throws
    /// Write ToRadio.wantConfigID; drain FromRadio until config complete; seed session_passkey via get_owner.
    func handshake() async throws
    func setLoRa(_ settings: LoRaSettings) async throws
    func setDevice(role: DeviceRole, settings: DeviceSettings) async throws
    func setPosition(_ settings: PositionSettings) async throws
    func setDisplay(_ settings: DisplaySettings) async throws
    /// `AdminMessage.set_owner` with session_passkey. Long name is the TAK callsign; short name is the mesh badge.
    func setOwner(longName: String, shortName: String) async throws
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
