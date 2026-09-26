import Foundation

/// A radio we've successfully (or last-attempted) configured. Persisted on phone — not on the mesh.
struct ConfiguredDevice: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    /// Stable-ish BLE identifier when available (may change after OS reboot / forget).
    var peripheralID: UUID?
    /// Meshtastic node number when known from handshake.
    var nodeNum: UInt32?
    var displayName: String
    var lastMACOrKey: String?
    var profileID: UUID
    var role: DeviceRole
    var lastAppliedAt: Date?
    var lastStatus: DeviceConfigStatus
    var notes: String

    init(
        id: UUID = UUID(),
        peripheralID: UUID? = nil,
        nodeNum: UInt32? = nil,
        displayName: String,
        lastMACOrKey: String? = nil,
        profileID: UUID,
        role: DeviceRole,
        lastAppliedAt: Date? = nil,
        lastStatus: DeviceConfigStatus = .pending,
        notes: String = ""
    ) {
        self.id = id
        self.peripheralID = peripheralID
        self.nodeNum = nodeNum
        self.displayName = displayName
        self.lastMACOrKey = lastMACOrKey
        self.profileID = profileID
        self.role = role
        self.lastAppliedAt = lastAppliedAt
        self.lastStatus = lastStatus
        self.notes = notes
    }
}

enum DeviceConfigStatus: String, Codable, Sendable {
    case pending
    case configured
    case failed
    case roleChangedNeedsReapply

    var label: String {
        switch self {
        case .pending: return "Pending"
        case .configured: return "Configured"
        case .failed: return "Failed"
        case .roleChangedNeedsReapply: return "Needs re-apply"
        }
    }
}

extension ConfiguredDevice {
    /// User changed role in the roster — mark dirty until BLE re-apply succeeds.
    /// Changing role does not write BLE by itself.
    mutating func setRole(_ newRole: DeviceRole) {
        guard newRole != role else { return }
        role = newRole
        lastStatus = .roleChangedNeedsReapply
    }

    mutating func markConfigured(at date: Date = Date()) {
        lastAppliedAt = date
        lastStatus = .configured
    }

    mutating func markFailed() {
        lastStatus = .failed
    }
}
