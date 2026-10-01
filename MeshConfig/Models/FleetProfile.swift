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

    /// OpenTAKServer MQTT bridge. The password lives in the Keychain, not in this value.
    var mqtt: MQTTSettings = .openTAK
    /// Wi-Fi networks applied only when the device function is Gateway.
    var wifiNetworks: [WifiNetwork] = []
}

extension FleetProfile {
    /// TAK template locks. Slot, region, channel name, MQTT address, Wi-Fi SSID,
    /// smart position, geoidal separation, units, notes, and the default role stay editable.
    /// Altitude is always the HAE path: ALTITUDE on, ALTITUDE_MSL off.
    /// Ignore MQTT stays off and Ok to MQTT stays on so a gateway will upload the fleet.
    mutating func applyTAKTemplateLocks() {
        lora.usePreset = true
        lora.modemPreset = .shortTurbo
        lora.ignoreMQTT = false
        lora.configOkToMQTT = true
        lora.hopLimit = 3
        lora.txEnabled = true
        // ALL, not CORE_PORTNUMS_ONLY. That mode drops ATAK_PLUGIN (port 72), so OTS chat never reaches a tracker.
        device.rebroadcastMode = .all
        position.flags.altitude = true
        position.flags.altitudeMSL = false
        channel.preciseLocation = true
        channel.replaceDefaultPrimary = true
        channel.uplinkEnabled = true
        channel.downlinkEnabled = true
        // Codable files store Keychain accounts only. Never a key or password.
        channel.pskRef.exportableBase64 = nil
        if mqtt.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mqtt.address = MQTTSettings.openTAK.address
        }
        if mqtt.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mqtt.username = MQTTSettings.openTAK.username
        }
        if mqtt.root.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            mqtt.root = MQTTSettings.openTAK.root
        }
    }
}

extension FleetProfile {
    enum CodingKeys: String, CodingKey {
        case id, name, notes, createdAt, updatedAt, lora, channel, device, position, display, defaultRole, mqtt, wifiNetworks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        notes = try container.decode(String.self, forKey: .notes)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lora = try container.decode(LoRaSettings.self, forKey: .lora)
        channel = try container.decode(ChannelSettings.self, forKey: .channel)
        device = try container.decode(DeviceSettings.self, forKey: .device)
        position = try container.decode(PositionSettings.self, forKey: .position)
        display = try container.decode(DisplaySettings.self, forKey: .display)
        defaultRole = try container.decode(DeviceRole.self, forKey: .defaultRole)
        mqtt = try container.decodeIfPresent(MQTTSettings.self, forKey: .mqtt) ?? .openTAK
        wifiNetworks = try container.decodeIfPresent([WifiNetwork].self, forKey: .wifiNetworks) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(notes, forKey: .notes)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(lora, forKey: .lora)
        try container.encode(channel, forKey: .channel)
        try container.encode(device, forKey: .device)
        try container.encode(position, forKey: .position)
        try container.encode(display, forKey: .display)
        try container.encode(defaultRole, forKey: .defaultRole)
        try container.encode(mqtt, forKey: .mqtt)
        try container.encode(wifiNetworks, forKey: .wifiNetworks)
    }
}

// MARK: - LoRa (Config.LoRa)

struct LoRaSettings: Hashable, Sendable {
    /// When true, modemPreset drives airtime; custom SF/BW ignored.
    var usePreset: Bool
    var modemPreset: ModemPreset
    /// TAK fleets leave this off so a gateway can deliver MQTT-path packets.
    var ignoreMQTT: Bool
    /// Explicit slot. 0 = hash from channel name (avoid for fleet lockstep).
    var frequencySlot: UInt32
    /// Region is device/regulatory; keep on profile so fleet stays consistent.
    var region: LoRaRegion
    /// Meshtastic `hop_limit`. TAK fleets use 3.
    var hopLimit: UInt32 = 3
    /// Meshtastic `tx_enabled`. TAK fleets leave the radio transmitting.
    var txEnabled: Bool = true
    /// Meshtastic `config_ok_to_mqtt`. Required or a gateway drops the packet.
    var configOkToMQTT: Bool = true
}

extension LoRaSettings: Codable {
    enum CodingKeys: String, CodingKey {
        case usePreset, modemPreset, ignoreMQTT, frequencySlot, region, hopLimit, txEnabled, configOkToMQTT
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usePreset = try container.decode(Bool.self, forKey: .usePreset)
        modemPreset = try container.decode(ModemPreset.self, forKey: .modemPreset)
        ignoreMQTT = try container.decodeIfPresent(Bool.self, forKey: .ignoreMQTT) ?? false
        frequencySlot = try container.decode(UInt32.self, forKey: .frequencySlot)
        region = try container.decode(LoRaRegion.self, forKey: .region)
        hopLimit = try container.decodeIfPresent(UInt32.self, forKey: .hopLimit) ?? 3
        txEnabled = try container.decodeIfPresent(Bool.self, forKey: .txEnabled) ?? true
        configOkToMQTT = try container.decodeIfPresent(Bool.self, forKey: .configOkToMQTT) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(usePreset, forKey: .usePreset)
        try container.encode(modemPreset, forKey: .modemPreset)
        try container.encode(ignoreMQTT, forKey: .ignoreMQTT)
        try container.encode(frequencySlot, forKey: .frequencySlot)
        try container.encode(region, forKey: .region)
        try container.encode(hopLimit, forKey: .hopLimit)
        try container.encode(txEnabled, forKey: .txEnabled)
        try container.encode(configOkToMQTT, forKey: .configOkToMQTT)
    }
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

/// Keychain account for a password this app types once and never shows again.
struct KeychainSecretRef: Codable, Hashable, Sendable {
    var keychainAccount: String

    static let empty = KeychainSecretRef(keychainAccount: "")

    var isConfigured: Bool { !keychainAccount.isEmpty }
}

/// OpenTAKServer Meshtastic MQTT bridge. Bool flags are fixed in the apply path, not stored here.
struct MQTTSettings: Codable, Hashable, Sendable {
    var address: String
    var username: String
    var passwordRef: KeychainSecretRef
    var root: String

    static let openTAK = MQTTSettings(
        address: "mcsctak.duckdns.org:8883",
        username: "meshgw",
        passwordRef: .empty,
        root: "opentakserver"
    )
}

/// One saved Wi-Fi network. The PSK is in the Keychain. Only Gateway devices receive it.
struct WifiNetwork: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var ssid: String
    var pskRef: KeychainSecretRef

    init(id: UUID = UUID(), ssid: String, pskRef: KeychainSecretRef = .empty) {
        self.id = id
        self.ssid = ssid
        self.pskRef = pskRef
    }
}

// MARK: - Device (Config.Device)

struct DeviceSettings: Codable, Hashable, Sendable {
    var rebroadcastMode: RebroadcastMode
    /// Optional POSIX TZ for standalones (Chaos Koalas example for US Eastern).
    var timezone: String?
}

enum DeviceRole: String, Codable, CaseIterable, Sendable {
    case client = "CLIENT"               // protobuf = 0; Wi-Fi MQTT gateway
    case tak = "TAK"                     // protobuf = 7; phone + ATAK/iTAK EUD
    case takTracker = "TAK_TRACKER"      // protobuf = 10; standalone tracker
    case clientBase = "CLIENT_BASE"      // fixed infrastructure; not default TAK profile

    var displayName: String {
        switch self {
        case .client: return "Client (gateway)"
        case .tak: return "TAK (paired with ATAK/iTAK)"
        case .takTracker: return "TAK Tracker (standalone)"
        case .clientBase: return "Client Base (fixed node)"
        }
    }

    var chipTitle: String {
        switch self {
        case .client: return "Client"
        case .tak: return "TAK"
        case .takTracker: return "TAK Tracker"
        case .clientBase: return "Client Base"
        }
    }

    var shortHelp: String {
        switch self {
        case .client:
            return "Gateway role. The radio joins Wi-Fi and uploads the fleet to OpenTAKServer. Wi-Fi disables Bluetooth after reboot."
        case .tak:
            return "Use when this radio is BLE-paired to a phone running ATAK/iTAK + Meshtastic Local TAK Server."
        case .takTracker:
            return "Use for standalone trackers with no ATAK EUD on the same phone."
        case .clientBase:
            return "Fixed high node; router for favorites. Separate from the TAK fleet profile."
        }
    }
}

/// Per-device job in the TAK fleet. Trackers keep the chosen TAK role. A gateway is CLIENT.
enum DeviceFunction: String, Codable, CaseIterable, Sendable {
    case tracker
    case gateway

    var displayName: String {
        switch self {
        case .tracker: return "Tracker"
        case .gateway: return "Gateway"
        }
    }

    var shortHelp: String {
        switch self {
        case .tracker:
            return "Position source. MQTT on this radio stays off. Role is TAK or TAK Tracker."
        case .gateway:
            return "Heltec-style node. Role CLIENT, Wi-Fi on, MQTT module pointed at OpenTAKServer."
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
            notes: "ShortTurbo ATAK mesh. One generated AES-256 PSK in Keychain per profile. Trackers and the gateway share the channel. The gateway Wi-Fi and MQTT passwords stay in the Keychain.",
            createdAt: now,
            updatedAt: now,
            lora: LoRaSettings(
                usePreset: true,
                modemPreset: .shortTurbo,
                ignoreMQTT: false,
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
                rebroadcastMode: .all,
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

    static func make(from profile: FleetProfile, role: DeviceRole) -> ProfileApplyPlan {
        // Sync writes only the sections that differ, inside one edit transaction.
        // The radio reboots at most once, when commit_edit_settings saves.
        ProfileApplyPlan(profile: profile, roleForThisDevice: role)
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
    var configOkToMQTT: Bool?
    var hopLimit: UInt32?
    var txEnabled: Bool?
    var frequencySlot: UInt32?
    var primaryChannelName: String?
    var primaryHasNonDefaultPSK: Bool?
    var preciseLocation: Bool?
    var uplinkEnabled: Bool?
    var downlinkEnabled: Bool?
    var role: DeviceRole?
    var rebroadcastMode: RebroadcastMode?
    var smartPosition: Bool?
    var positionFlags: PositionFlagSet?
    /// Meshtastic `User.long_name` read back from the radio.
    var longName: String?
    var wifiEnabled: Bool?
    var wifiSSID: String?
    var mqttEnabled: Bool?
    var mqttAddress: String?
    var mqttUsername: String?
    var mqttRoot: String?
    var mqttEncryptionEnabled: Bool?
    var mqttJSONEnabled: Bool?
    var mqttTLSEnabled: Bool?
    var mqttProxyEnabled: Bool?
    var mqttMapReportingEnabled: Bool?
    /// MQTT module body. May contain the MQTT password. Do not log this snapshot.
    var mqttBody: Data = Data()
    /// Network config body. May contain the Wi-Fi password. Do not log this snapshot.
    var networkBody: Data = Data()
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
        ("lora.mqtt", "Ignore MQTT is off"),
        ("lora.okToMqtt", "Ok to MQTT is on"),
        ("lora.hop", "Hop limit is 3"),
        ("lora.tx", "Transmit is on"),
        ("lora.slot", "Frequency slot is 50 (or profile override)"),
        ("ch.name", "Primary channel is private (not LongFast/ShortFast)"),
        ("ch.psk", "Primary PSK is non-default AES-256"),
        ("ch.precise", "Precise location is on"),
        ("ch.uplink", "Primary channel uplink is on"),
        ("ch.downlink", "Primary channel downlink is on"),
        ("dev.role", "Role matches the function chosen at apply"),
        ("owner.longName", "Long name matches when a new callsign was written"),
        ("dev.rebroadcast", "Rebroadcast is ALL"),
        ("pos.smart", "Smart Position matches profile (on for ops)"),
        ("pos.hae", "Position flags: ALTITUDE on, ALTITUDE_MSL off"),
        ("pos.geoid", "GEOIDAL_SEPARATION on when profile requests it"),
    ]

    static func evaluate(
        profile: FleetProfile,
        snap: DeviceSnapshot,
        appliedRole: DeviceRole,
        appliedLongName: String?,
        function: DeviceFunction,
        wifiSSID: String,
        wifiPSK: Data,
        mqttPassword: Data
    ) -> [VerifyCheckResult] {
        var rows = [
            VerifyCheckResult(id: "lora.preset", label: "LoRa preset is ShortTurbo", ok: snap.modemPreset == .shortTurbo),
            VerifyCheckResult(id: "lora.mqtt", label: "Ignore MQTT is off", ok: snap.ignoreMQTT == false),
            VerifyCheckResult(id: "lora.okToMqtt", label: "Ok to MQTT is on", ok: snap.configOkToMQTT == true),
            VerifyCheckResult(id: "lora.hop", label: "Hop limit is 3", ok: snap.hopLimit == profile.lora.hopLimit),
            VerifyCheckResult(id: "lora.tx", label: "Transmit is on", ok: snap.txEnabled == true),
            VerifyCheckResult(id: "lora.slot", label: "Frequency slot matches profile", ok: snap.frequencySlot == profile.lora.frequencySlot),
            VerifyCheckResult(id: "ch.name", label: "Primary channel is private", ok: {
                guard let name = snap.primaryChannelName?.lowercased() else { return false }
                return name != "longfast" && name != "shortfast" && name == profile.channel.name.lowercased()
            }()),
            VerifyCheckResult(id: "ch.psk", label: "Primary PSK is non-default AES-256", ok: snap.primaryHasNonDefaultPSK == true),
            VerifyCheckResult(id: "ch.precise", label: "Precise location is on", ok: snap.preciseLocation == true),
            VerifyCheckResult(id: "ch.uplink", label: "Primary channel uplink is on", ok: snap.uplinkEnabled == true),
            VerifyCheckResult(id: "ch.downlink", label: "Primary channel downlink is on", ok: snap.downlinkEnabled == true),
            VerifyCheckResult(id: "dev.role", label: "Role matches apply choice", ok: snap.role == appliedRole),
            VerifyCheckResult(
                id: "owner.longName",
                label: appliedLongName == nil
                    ? "Long name left as the radio already had it"
                    : "Long name matches the TAK callsign",
                ok: appliedLongName == nil || snap.longName == appliedLongName
            ),
            VerifyCheckResult(id: "dev.rebroadcast", label: "Rebroadcast is ALL", ok: snap.rebroadcastMode == .all),
            VerifyCheckResult(id: "pos.smart", label: "Smart Position matches profile", ok: snap.smartPosition == profile.position.smartPosition),
            VerifyCheckResult(id: "pos.hae", label: "Altitude is HAE path (not MSL)", ok: snap.positionFlags?.isTAKAltitudeCorrect == true),
            VerifyCheckResult(id: "pos.geoid", label: "Geoidal separation matches profile", ok: snap.positionFlags?.geoidalSeparation == profile.position.flags.geoidalSeparation),
        ]
        if function == .gateway {
            rows.append(VerifyCheckResult(id: "network.wifi", label: "Wi-Fi is on and the SSID matches", ok: snap.wifiEnabled == true && snap.wifiSSID == wifiSSID))
            let radioWiFi = PhoneAPICodec.bytes(tryParse(snap.networkBody), 4) ?? Data()
            rows.append(VerifyCheckResult(
                id: "network.wifiPsk",
                label: "Wi-Fi password matches the Keychain password",
                ok: !wifiPSK.isEmpty && radioWiFi == wifiPSK
            ))
            rows.append(VerifyCheckResult(id: "mqtt.enabled", label: "MQTT module is on", ok: snap.mqttEnabled == true))
            rows.append(VerifyCheckResult(id: "mqtt.address", label: "MQTT address matches the profile", ok: snap.mqttAddress == profile.mqtt.address))
            rows.append(VerifyCheckResult(id: "mqtt.username", label: "MQTT username matches the profile", ok: snap.mqttUsername == profile.mqtt.username))
            let radioMQTT = PhoneAPICodec.bytes(tryParse(snap.mqttBody), 4) ?? Data()
            rows.append(VerifyCheckResult(
                id: "mqtt.password",
                label: "MQTT password matches the Keychain password",
                ok: !mqttPassword.isEmpty && radioMQTT == mqttPassword
            ))
            rows.append(VerifyCheckResult(id: "mqtt.root", label: "MQTT root topic matches the profile", ok: snap.mqttRoot == profile.mqtt.root))
            rows.append(VerifyCheckResult(id: "mqtt.flags", label: "MQTT encryption, JSON, TLS, proxy, and map reporting are off", ok: snap.mqttEncryptionEnabled == false && snap.mqttJSONEnabled == false && snap.mqttTLSEnabled == false && snap.mqttProxyEnabled == false && snap.mqttMapReportingEnabled == false))
        } else {
            rows.append(VerifyCheckResult(id: "mqtt.enabled", label: "MQTT module is off", ok: snap.mqttEnabled != true))
        }
        return rows
    }

    private static func tryParse(_ data: Data) -> [PhoneAPICodec.Field] {
        (try? PhoneAPICodec.parse(data)) ?? []
    }
}
