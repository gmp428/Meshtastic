import Foundation

/// A Meshtastic-looking peripheral from a scan. Names and RSSI only — no keys.
struct DiscoveredRadio: Identifiable, Hashable, Sendable {
    var peripheralID: UUID
    var name: String
    var rssi: Int
    /// True only for the DEBUG simulated transport. CoreBluetooth leaves this false.
    var isSimulated: Bool

    var id: UUID { peripheralID }
}

enum MeshtasticBLEError: Error, Equatable {
    case bluetoothUnavailable
    case bluetoothOff
    case unauthorized
    case timedOut
    case notConnected
    case serviceNotFound
    case protobufNotIntegrated(String)
    case adminFailed(String)
    case invalidPSKLength
    case cancelled
}

extension MeshtasticBLEError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is unavailable on this iPhone."
        case .bluetoothOff:
            return "Bluetooth is off. Turn it on in Settings, then scan again."
        case .unauthorized:
            return "Bluetooth permission is off for Mesh Config. Enable it in Settings."
        case .timedOut:
            return "The radio did not respond before the timeout."
        case .notConnected:
            return "The radio is not connected."
        case .serviceNotFound:
            return "The Meshtastic Bluetooth service was not found on this radio."
        case .protobufNotIntegrated(let step):
            return "\(step) needs Meshtastic protobuf admin messages. This build will not pretend that write succeeded."
        case .adminFailed(let message):
            return message
        case .invalidPSKLength:
            return "The fleet PSK must be 32 bytes before a channel write."
        case .cancelled:
            return "cancelled"
        }
    }
}

/// Scan/connect extras around `MeshtasticBLETransport`. Policy stays in `ApplySession`.
@MainActor
protocol FleetRadioTransport: MeshtasticBLETransport {
    var onDiscovered: (@MainActor (DiscoveredRadio) -> Void)? { get set }
    var onBluetoothBlocked: (@MainActor (String?) -> Void)? { get set }
    /// Link dropped outside an expected reboot wait. Apply policy decides whether that is fatal.
    var onUnexpectedLinkLoss: (@MainActor () -> Void)? { get set }
    func stopScan()
    /// After a reboot-triggering admin save, wait until the link drops or the grace timer fires.
    func waitForLinkDrop(timeout: TimeInterval) async -> Bool
}
