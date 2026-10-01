import Combine
import Foundation

// MARK: - One-radio BLE apply session (sequential fleet; never two at once)

enum ApplySessionState: Equatable, Sendable {
    case idle
    case scanning
    case connecting
    case handshaking          // wantConfig + drain FromRadio + seed session_passkey
    case ensuringPSK
    case comparing            // diff the radio against the profile; no writes yet
    case applyingChanges      // one begin/commit edit transaction
    case waitingReboot        // commit asked the radio to reboot
    case reconnecting
    case verifying
    case succeeded
    /// Indirect: ApplyFailure stores the stage, so this case makes the type recursive.
    indirect case failed(ApplyFailure)
    case disconnecting
    case disconnected
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
    /// How long to wait for Bluetooth to drop after the single commit reboot.
    var rebootGrace: TimeInterval = 60
    /// How long to keep trying Bluetooth after that drop, including a slow boot.
    var reconnectTimeout: TimeInterval = 90
}

/// Orchestrates scan → connect → handshake → diff → one transaction → verify → disconnect.
/// BLE transport is injected (CoreBluetooth + Meshtastic protobuf); this type owns policy.
@MainActor
final class ApplySession: ObservableObject {
    @Published private(set) var state: ApplySessionState = .idle
    @Published private(set) var lastChecklist: [VerifyCheckResult] = []
    @Published private(set) var shownLongName: String = ""
    @Published private(set) var shownShortName: String = ""
    @Published private(set) var syncProgress: SyncProgress?

    let profile: FleetProfile
    let role: DeviceRole
    let function: DeviceFunction
    let wifiNetworkID: UUID?
    let config: ApplySessionConfig

    private let requestedLongName: String?
    private let requestedShortName: String?
    /// False when that field was filled from the roster and the user has not typed in it.
    private let longEdited: Bool
    private let shortEdited: Bool
    /// Set after commit so the post-reboot handshake verifies instead of writing again.
    private var resumeToVerify = false
    private var radioLongName: String?
    private var radioShortName: String?
    private var writtenLongName: String?
    private var writtenShortName: String?

    init(
        profile: FleetProfile,
        role: DeviceRole,
        function: DeviceFunction,
        wifiNetworkID: UUID?,
        names: RadioNames,
        longEdited: Bool,
        shortEdited: Bool,
        config: ApplySessionConfig = .init()
    ) {
        self.profile = profile
        self.role = role
        self.function = function
        self.wifiNetworkID = wifiNetworkID
        self.requestedLongName = names.longName
        self.requestedShortName = names.shortName
        self.longEdited = longEdited
        self.shortEdited = shortEdited
        self.config = config
        self.shownLongName = names.longName ?? ""
        self.shownShortName = names.shortName ?? ""
    }

    var nameRequest: RadioNames {
        RadioNames(longName: requestedLongName, shortName: requestedShortName)
    }

    var didEditLongName: Bool { longEdited }
    var didEditShortName: Bool { shortEdited }

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

    /// Names to remember after a passing verify. Unchanged fields keep the radio's current value.
    var namesForRoster: RadioNames? {
        let long = writtenLongName ?? radioLongName
        let short = writtenShortName ?? radioShortName
        let hasLong = long?.isEmpty == false
        let hasShort = short?.isEmpty == false
        guard hasLong || hasShort else { return nil }
        return RadioNames(longName: hasLong ? long : nil, shortName: hasShort ? short : nil)
    }

    var resultLongName: String {
        writtenLongName ?? radioLongName ?? requestedLongName ?? ""
    }

    var resultShortName: String {
        writtenShortName ?? radioShortName ?? requestedShortName ?? ""
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
            resumeToVerify = false
        }
        state = .handshaking
    }

    /// After wantConfig drain + session_passkey seeded.
    func onHandshakeComplete() async {
        guard state == .handshaking else { return }
        if resumeToVerify {
            resumeToVerify = false
            state = .verifying
            return
        }
        state = .ensuringPSK
        do {
            var mutable = profile
            try FleetPSKStore.ensurePSK(for: &mutable)
            state = .comparing
        } catch {
            fail(stage: .ensuringPSK, message: "Could not ensure fleet PSK in Keychain.", checks: [])
        }
    }

    /// Owner strings read from the radio. Unedited fields display these instead of a stale roster prefill.
    func noteRadioOwner(longName: String?, shortName: String?) {
        radioLongName = longName
        radioShortName = shortName
        refreshShownNames()
    }

    func adoptPlan(_ plan: SyncPlan) {
        guard state == .comparing else { return }
        writtenLongName = plan.writtenLongName
        writtenShortName = plan.writtenShortName
        syncProgress = plan.progress
        refreshShownNames()
        state = plan.isEmpty ? .verifying : .applyingChanges
    }

    func onChangesCommitted() {
        guard state == .applyingChanges else { return }
        resumeToVerify = true
        state = .waitingReboot
    }

    func onLinkLost() {
        if case .waitingReboot = state {
            state = .reconnecting
            return
        }
        // The radio can drop again while it is still booting. That is part of the reconnect.
        if resumeToVerify {
            switch state {
            case .handshaking, .reconnecting:
                state = .reconnecting
                return
            default:
                break
            }
        }
        if !isTerminal && state != .disconnecting && state != .disconnected {
            fail(stage: state, message: "BLE link lost unexpectedly.", checks: [])
        }
    }

    /// Handshake failed before the post-reboot window ended. Stay in reconnect and try again.
    func resumeReconnectWait() {
        guard resumeToVerify else { return }
        if case .handshaking = state {
            state = .reconnecting
        }
    }

    func onVerified(snapshot: DeviceSnapshot, wifiPSK: Data, mqttPassword: Data) {
        guard state == .verifying else { return }
        let ssid = profile.wifiNetworks.first { $0.id == wifiNetworkID }?.ssid
            ?? profile.wifiNetworks.first?.ssid
            ?? ""
        let results = ProfileAcceptance.evaluate(
            profile: profile,
            snap: snapshot,
            appliedRole: role,
            appliedLongName: writtenLongName,
            function: function,
            wifiSSID: ssid,
            wifiPSK: wifiPSK,
            mqttPassword: mqttPassword
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

    private func refreshShownNames() {
        if longEdited {
            shownLongName = writtenLongName ?? requestedLongName ?? radioLongName ?? ""
        } else {
            shownLongName = radioLongName ?? requestedLongName ?? ""
        }
        if shortEdited {
            shownShortName = writtenShortName ?? requestedShortName ?? radioShortName ?? ""
        } else {
            shownShortName = radioShortName ?? requestedShortName ?? ""
        }
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
    /// Full config captured by the last handshake. Nil before handshake and after disconnect.
    func radioInventory() -> RadioInventory?
    /// `begin_edit_settings`, the differing writes, then `commit_edit_settings`. Empty input writes nothing.
    func applyTransaction(_ writes: [SyncWrite]) async throws
    func readSnapshot() async throws -> DeviceSnapshot
    func disconnect() async
}
