import Foundation

// MARK: - Fleet profile (saved on phone; applied one radio at a time over BLE)

/// One named fleet configuration. Channel PSK must match across devices that should join the same mesh.
struct FleetProfile: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    var lora: LoRaSettings
    var channel: ChannelSettings
    var device: DeviceSettings
    var position: PositionSettings
    var display: DisplaySettings

    /// Role chosen at apply time (not baked into every profile the same way).
    /// Profiles still carry a *default* role; the apply UI can override per device.
    var defaultRole: DeviceRole
}

extension FleetProfile {
    /// TAK template locks. Slot, region, channel name, Ignore MQTT, smart position,
    /// geoidal separation, units, notes, and the default role stay editable.
    /// Altitude is always the HAE path: ALTITUDE on, ALTITUDE_MSL off.
    mutating func applyTAKTemplateLocks() {
        lora.usePreset = true
        lora.modemPreset = .shortTurbo
        device.rebroadcastMode = .localOnly
        position.flags.altitude = true
        position.flags.altitudeMSL = false
        channel.preciseLocation = true
        channel.replaceDefaultPrimary = true
        channel.uplinkEnabled = true
        channel.downlinkEnabled = true
        // Codable files store the Keychain account only. Never a key.
        channel.pskRef.exportableBase64 = nil
    }
}

// MARK: - LoRa (Config.LoRa)

struct LoRaSettings: Codable, Hashable, Sendable {
    /// When true, modemPreset drives airtime; custom SF/BW ignored.
    var usePreset: Bool
    var modemPreset: ModemPreset
    var ignoreMQTT: Bool
    /// Explicit slot. 0 = hash from channel name (avoid for fleet lockstep).
    var frequencySlot: UInt32
    /// Region is device/regulatory; keep on profile so fleet stays consistent.
    var region: LoRaRegion
}

enum ModemPreset: String, Codable, CaseIterable, Sendable {
    case shortTurbo = "SHORT_TURBO"   // protobuf = 8
    case mediumFast = "MEDIUM_FAST"
    case longFast = "LONG_FAST"       // not for TAK/ATAK bandwidth

    var displayName: String {
        switch self {
        case .shortTurbo: return "Short Range - Turbo"
        case .mediumFast: return "Medium Fast"
        case .longFast: return "Long Fast"
        }
    }
}

enum LoRaRegion: String, Codable, CaseIterable, Sendable {
    case us = "US"
    case eu868 = "EU_868"
    case unset = "UNSET"
    // Extend as needed; apply layer maps to Config.LoRa.RegionCode

    var displayName: String {
        switch self {
        case .us: return "US"
        case .eu868: return "EU 868"
        case .unset: return "Unset"
        }
    }
}

// MARK: - Channel (ChannelSettings / Channel)

struct ChannelSettings: Codable, Hashable, Sendable {
    /// Primary channel name. Must be non-default for Local TAK Server "Fix Channel" rules.
    var name: String
    /// AES-256 key material. Never log or put in screenshots.
    /// Stored as Keychain reference id in persistence; in-memory as Data(32).
    var pskRef: PSKReference
    var uplinkEnabled: Bool
    var downlinkEnabled: Bool
    /// Precise location on the channel (Meshtastic channel setting).
    var preciseLocation: Bool
    /// When applying: delete stock LongFast/ShortFast primary first, then write this as primary, then Send.
    var replaceDefaultPrimary: Bool

    /// Empty, LongFast, and ShortFast are not a private TAK primary.
    var isDisallowedPrimaryName: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty || trimmed == "longfast" || trimmed == "shortfast"
    }
}

/// Opaque handle so Codable profiles never embed raw key bytes in plain files by default.
struct PSKReference: Codable, Hashable, Sendable {
    /// Keychain account / secret id. Empty means generate at first save or apply.
    var keychainAccount: String
    /// Unused in generate-once mode; kept nil. No paste/import path in v1.
    var exportableBase64: String? = nil

    static let empty = PSKReference(keychainAccount: "", exportableBase64: nil)

    /// True when Keychain account is set (bytes live only in Keychain).
    var isConfigured: Bool { !keychainAccount.isEmpty }
}

// MARK: - Device (Config.Device)

struct DeviceSettings: Codable, Hashable, Sendable {
    var rebroadcastMode: RebroadcastMode
    /// Optional POSIX TZ for standalones (Chaos Koalas example for US Eastern).
    var timezone: String?
}

enum DeviceRole: String, Codable, CaseIterable, Sendable {
    case tak = "TAK"                     // protobuf = 7; phone + ATAK/iTAK EUD
    case takTracker = "TAK_TRACKER"      // protobuf = 10; standalone tracker
    case clientBase = "CLIENT_BASE"      // fixed infrastructure; not default TAK profile

    var displayName: String {
        switch self {
        case .tak: return "TAK (paired with ATAK/iTAK)"
        case .takTracker: return "TAK Tracker (standalone)"
        case .clientBase: return "Client Base (fixed node)"
        }
    }

    var chipTitle: String {
        switch self {
        case .tak: return "TAK"
        case .takTracker: return "TAK Tracker"
        case .clientBase: return "Client Base"
        }
    }

    var shortHelp: String {
        switch self {
        case .tak:
            return "Use when this radio is BLE-paired to a phone running ATAK/iTAK + Meshtastic Local TAK Server."
        case .takTracker:
            return "Use for standalone trackers with no ATAK EUD on the same phone."
        case .clientBase:
            return "Fixed high node; router for favorites. Separate from the TAK fleet profile."
        }
    }
}

enum RebroadcastMode: String, Codable, CaseIterable, Sendable {
    case localOnly = "LOCAL_ONLY"
    case all = "ALL"
    case none = "NONE"
}

// MARK: - Position (Config.Position)

struct PositionSettings: Codable, Hashable, Sendable {
    var smartPosition: Bool
    /// Bitfield intent; apply layer ORs protobuf PositionFlags.
    var flags: PositionFlagSet
    var gpsMode: GPSMode
}

struct PositionFlagSet: Codable, Hashable, Sendable {
    /// Include altitude. For TAK CoT `hae`, use ALTITUDE and do NOT set ALTITUDE_MSL.
    var altitude: Bool
    var altitudeMSL: Bool
    /// Prefer on so HAE can be derived correctly when the radio provides separation.
    var geoidalSeparation: Bool

    /// Maps to Meshtastic PositionFlags bitfield at apply time.
    var protobufIntent: [String] {
        var out: [String] = []
        if altitude { out.append("ALTITUDE") }
        if altitudeMSL { out.append("ALTITUDE_MSL") }
        if geoidalSeparation { out.append("GEOIDAL_SEPARATION") }
        return out
    }

    /// TAK-correct altitude: HAE path, not MSL.
    var isTAKAltitudeCorrect: Bool { altitude && !altitudeMSL }
}

enum GPSMode: String, Codable, CaseIterable, Sendable {
    case enabled = "ENABLED"
    case disabled = "DISABLED"
    case notPresent = "NOT_PRESENT"
}

// MARK: - Display (Config.Display)

struct DisplaySettings: Codable, Hashable, Sendable {
    var units: DisplayUnits
}

enum DisplayUnits: String, Codable, CaseIterable, Sendable {
    case metric = "METRIC"
    case imperial = "IMPERIAL"

    var displayName: String {
        switch self {
        case .metric: return "Metric"
        case .imperial: return "Imperial"
        }
    }
}

// MARK: - Built-in: Chaos Koalas / Chris TAK tracker defaults

enum BuiltInProfiles {
    /// Primary fleet profile for ATAK-over-Meshtastic (Chaos Koalas guide, verified ~Sep 2026).
    static func takTracker(
        name: String = "TAK Tracker",
        region: LoRaRegion = .us,
        displayUnits: DisplayUnits = .imperial,
        pskRef: PSKReference = .empty,
        channelName: String = "TAK"
    ) -> FleetProfile {
        let now = Date()
        return FleetProfile(
            id: UUID(),
            name: name,
            notes: "ShortTurbo ATAK mesh. One generated AES-256 PSK in Keychain per profile; same channel name + PSK on every radio. Role overridden per device at apply time.",
            createdAt: now,
            updatedAt: now,
            lora: LoRaSettings(
                usePreset: true,
                modemPreset: .shortTurbo,
                ignoreMQTT: true,
                frequencySlot: 50,
                region: region
            ),
            channel: ChannelSettings(
                name: channelName,
                // PSK: generate once via FleetPSKStore.ensurePSK; never embed raw key in Codable JSON.
                pskRef: pskRef,
                uplinkEnabled: true,
                downlinkEnabled: true,
                preciseLocation: true,
                replaceDefaultPrimary: true
            ),
            device: DeviceSettings(
                rebroadcastMode: .localOnly,
                timezone: "EST5EDT,M3.2.0/2,M11.1.0/2" // optional; standalones
            ),
            position: PositionSettings(
                smartPosition: true,
                flags: PositionFlagSet(
                    altitude: true,
                    altitudeMSL: false,
                    geoidalSeparation: true
                ),
                gpsMode: .enabled
            ),
            display: DisplaySettings(units: displayUnits),
            defaultRole: .takTracker
        )
    }
}

// MARK: - Apply plan (what BLE writer must do, in order)

struct ProfileApplyPlan: Sendable {
    var profile: FleetProfile
    var roleForThisDevice: DeviceRole
    var expectRebootAfter: Set<ApplySection>

    static func make(from profile: FleetProfile, role: DeviceRole) -> ProfileApplyPlan {
        // LoRa / Device / Position / Display trigger reboot on save; Channel does not (Chaos Koalas).
        ProfileApplyPlan(
            profile: profile,
            roleForThisDevice: role,
            expectRebootAfter: [.owner, .lora, .device, .position, .display]
        )
    }
}

// MARK: - Acceptance checks (verify after apply / reconnect)

struct ProfileAcceptanceCheck: Identifiable, Sendable {
    var id: String
    var label: String
    var passes: @Sendable (FleetProfile, DeviceSnapshot) -> Bool
}

/// Minimal read-back from radio after apply.
struct DeviceSnapshot: Sendable {
    var modemPreset: ModemPreset?
    var ignoreMQTT: Bool?
    var frequencySlot: UInt32?
    var primaryChannelName: String?
    var primaryHasNonDefaultPSK: Bool?
    var preciseLocation: Bool?
    var role: DeviceRole?
    var rebroadcastMode: RebroadcastMode?
    var smartPosition: Bool?
    var positionFlags: PositionFlagSet?
    /// Meshtastic `User.long_name` read back from the radio.
    var longName: String?
}

/// One TAK verify row. A named type so checklists can live in `Equatable` results.
/// Swift tuples do not conform to `Equatable`, so `[tuple]` blocks synthesized conformance.
struct VerifyCheckResult: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var ok: Bool
}

enum ProfileAcceptance {
    static let takChecks: [(id: String, label: String)] = [
        ("lora.preset", "LoRa preset is ShortTurbo"),
        ("lora.mqtt", "Ignore MQTT is on"),
        ("lora.slot", "Frequency slot is 50 (or profile override)"),
        ("ch.name", "Primary channel is private (not LongFast/ShortFast)"),
        ("ch.psk", "Primary PSK is non-default AES-256"),
        ("ch.precise", "Precise location is on"),
        ("dev.role", "Role is TAK or TAK_TRACKER as chosen at apply"),
        ("owner.longName", "Long name matches the TAK callsign entered at apply"),
        ("dev.rebroadcast", "Rebroadcast is LOCAL_ONLY"),
        ("pos.smart", "Smart Position matches profile (on for ops)"),
        ("pos.hae", "Position flags: ALTITUDE on, ALTITUDE_MSL off"),
        ("pos.geoid", "GEOIDAL_SEPARATION on when profile requests it"),
    ]

    static func evaluate(
        profile: FleetProfile,
        snap: DeviceSnapshot,
        appliedRole: DeviceRole,
        appliedLongName: String
    ) -> [VerifyCheckResult] {
        [
            VerifyCheckResult(id: "lora.preset", label: "LoRa preset is ShortTurbo", ok: snap.modemPreset == .shortTurbo),
            VerifyCheckResult(id: "lora.mqtt", label: "Ignore MQTT is on", ok: snap.ignoreMQTT == true),
            VerifyCheckResult(id: "lora.slot", label: "Frequency slot matches profile", ok: snap.frequencySlot == profile.lora.frequencySlot),
            VerifyCheckResult(id: "ch.name", label: "Primary channel is private", ok: {
                guard let n = snap.primaryChannelName?.lowercased() else { return false }
                return n != "longfast" && n != "shortfast" && n == profile.channel.name.lowercased()
            }()),
            VerifyCheckResult(id: "ch.psk", label: "Primary PSK is non-default AES-256", ok: snap.primaryHasNonDefaultPSK == true),
            VerifyCheckResult(id: "ch.precise", label: "Precise location is on", ok: snap.preciseLocation == true),
            VerifyCheckResult(id: "dev.role", label: "Role matches apply choice", ok: snap.role == appliedRole),
            VerifyCheckResult(
                id: "owner.longName",
                label: "Long name matches the TAK callsign",
                ok: snap.longName == appliedLongName && !appliedLongName.isEmpty
            ),
            VerifyCheckResult(id: "dev.rebroadcast", label: "Rebroadcast is LOCAL_ONLY", ok: snap.rebroadcastMode == .localOnly),
            VerifyCheckResult(id: "pos.smart", label: "Smart Position matches profile", ok: snap.smartPosition == profile.position.smartPosition),
            VerifyCheckResult(id: "pos.hae", label: "Altitude is HAE path (not MSL)", ok: snap.positionFlags?.isTAKAltitudeCorrect == true),
            VerifyCheckResult(id: "pos.geoid", label: "Geoidal separation matches profile", ok: snap.positionFlags?.geoidalSeparation == profile.position.flags.geoidalSeparation),
        ]
    }
}
