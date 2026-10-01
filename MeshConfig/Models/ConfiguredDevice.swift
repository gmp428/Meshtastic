import Foundation

/// A radio we've successfully (or last-attempted) configured. Persisted on phone — not on the mesh.
struct ConfiguredDevice: Identifiable, Hashable, Sendable {
    var id: UUID
    /// Stable-ish BLE identifier when available (may change after OS reboot / forget).
    var peripheralID: UUID?
    /// Meshtastic node number when known from handshake.
    var nodeNum: UInt32?
    var displayName: String
    var lastMACOrKey: String?
    var profileID: UUID
    var role: DeviceRole
    /// Tracker (default) or Gateway. Older roster files decode as Tracker.
    var function: DeviceFunction
    /// Saved Wi-Fi row used the last time this gateway was applied.
    var wifiNetworkID: UUID?
    /// Meshtastic long name applied to this radio. This is the TAK callsign / PLI name.
    var longName: String?
    /// Meshtastic short name applied to this radio. This is the 4-character mesh badge.
    var shortName: String?
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
        function: DeviceFunction = .tracker,
        wifiNetworkID: UUID? = nil,
        longName: String? = nil,
        shortName: String? = nil,
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
        self.function = function
        self.wifiNetworkID = wifiNetworkID
        self.longName = longName
        self.shortName = shortName
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

extension ConfiguredDevice: Codable {
    enum CodingKeys: String, CodingKey {
        case id, peripheralID, nodeNum, displayName, lastMACOrKey, profileID, role, function, wifiNetworkID
        case longName, shortName, lastAppliedAt, lastStatus, notes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        peripheralID = try container.decodeIfPresent(UUID.self, forKey: .peripheralID)
        nodeNum = try container.decodeIfPresent(UInt32.self, forKey: .nodeNum)
        displayName = try container.decode(String.self, forKey: .displayName)
        lastMACOrKey = try container.decodeIfPresent(String.self, forKey: .lastMACOrKey)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        role = try container.decode(DeviceRole.self, forKey: .role)
        function = try container.decodeIfPresent(DeviceFunction.self, forKey: .function) ?? .tracker
        wifiNetworkID = try container.decodeIfPresent(UUID.self, forKey: .wifiNetworkID)
        longName = try container.decodeIfPresent(String.self, forKey: .longName)
        shortName = try container.decodeIfPresent(String.self, forKey: .shortName)
        lastAppliedAt = try container.decodeIfPresent(Date.self, forKey: .lastAppliedAt)
        lastStatus = try container.decode(DeviceConfigStatus.self, forKey: .lastStatus)
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(peripheralID, forKey: .peripheralID)
        try container.encodeIfPresent(nodeNum, forKey: .nodeNum)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(lastMACOrKey, forKey: .lastMACOrKey)
        try container.encode(profileID, forKey: .profileID)
        try container.encode(role, forKey: .role)
        try container.encode(function, forKey: .function)
        try container.encodeIfPresent(wifiNetworkID, forKey: .wifiNetworkID)
        try container.encodeIfPresent(longName, forKey: .longName)
        try container.encodeIfPresent(shortName, forKey: .shortName)
        try container.encodeIfPresent(lastAppliedAt, forKey: .lastAppliedAt)
        try container.encode(lastStatus, forKey: .lastStatus)
        try container.encode(notes, forKey: .notes)
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

/// Per-radio names chosen at Apply time. Not stored on the fleet profile.
/// A nil field means “do not change this name on the radio.”
struct RadioNames: Equatable, Sendable {
    var longName: String?
    var shortName: String?

    /// Firmware stores at most 24 UTF-8 bytes and truncates anything longer before rebroadcast.
    static let maxLongNameUTF8Bytes = 24
    /// Nanopb `short_name` is 4 bytes plus a terminator.
    static let maxShortNameUTF8Bytes = 4

    enum Problem: Error, Equatable {
        case longNameTooLong
        case shortNameTooLong
    }

    /// Blank fields stay nil. A blank short name is not derived from the long name.
    static func resolve(longName: String, shortName: String) throws -> RadioNames {
        let long = longName.trimmingCharacters(in: .whitespacesAndNewlines)
        let short = shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !long.isEmpty {
            guard Data(long.utf8).count <= maxLongNameUTF8Bytes else { throw Problem.longNameTooLong }
        }
        if !short.isEmpty {
            guard Data(short.utf8).count <= maxShortNameUTF8Bytes else { throw Problem.shortNameTooLong }
        }
        return RadioNames(
            longName: long.isEmpty ? nil : long,
            shortName: short.isEmpty ? nil : short
        )
    }
}

extension RadioNames.Problem: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .longNameTooLong:
            return "The long name must be 24 bytes or fewer. That is the name ATAK shows."
        case .shortNameTooLong:
            return "The short name must fit in 4 bytes. That is the mesh badge."
        }
    }
}
