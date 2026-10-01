import Foundation

/// Safe-to-show description of a sync. Payloads that contain key material stay in `SyncPlan.writes`.
struct SyncProgress: Equatable, Sendable {
    var summary: String
    var changes: [SyncChange]
    var isEmpty: Bool

    var titles: [String] { changes.map(\.title) }

    /// On-screen log. Field ids and decoded labels only. Never key bytes.
    var debugLines: [String] {
        if changes.isEmpty { return ["No fields differed"] }
        return changes.map { "\($0.id): \($0.detail)" }
    }
}

struct SyncChange: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
    var detail: String
}

enum SyncWrite: Equatable, Sendable {
    /// Merged `User` bytes. May contain the node public key. Do not log.
    case owner(Data)
    /// Merged config subsection body.
    case config(PhoneAPICodec.ConfigKind, Data)
    /// Merged primary `Channel` message. Contains the PSK. Do not log.
    case channel(Data)
    /// Inner `MQTTConfig` body. Contains the MQTT password when this is a gateway write. Do not log.
    case moduleMQTT(Data)
}

struct SyncPlan: Equatable, Sendable {
    var changes: [SyncChange]
    var writes: [SyncWrite]
    /// Non-nil only when this sync will change that name.
    var writtenLongName: String?
    var writtenShortName: String?

    var isEmpty: Bool { writes.isEmpty }

    var summary: String {
        if changes.isEmpty { return "Already up to date" }
        if changes.count == 1 { return "1 setting will change" }
        return "\(changes.count) settings will change"
    }

    var progress: SyncProgress {
        SyncProgress(summary: summary, changes: changes, isEmpty: isEmpty)
    }
}

/// Everything the handshake read that a later diff can compare.
/// Channel messages and the owner record can hold key material. Do not log this value.
struct RadioInventory: Equatable, Sendable {
    var lora: Data
    var device: Data
    var position: Data
    var display: Data
    var owner: Data
    var longName: String?
    var shortName: String?
    var channels: [Data]
    /// Config oneof field numbers seen during the drain, including sections this app does not write.
    var observedConfigFields: Set<Int>
    /// ModuleConfig oneof field numbers seen during the drain. Bodies other than MQTT are not kept.
    var observedModuleFields: Set<Int>
    /// `Config.Network` body. May contain the Wi-Fi password. Do not log.
    var network: Data = Data()
    /// Inner `MQTTConfig` body. May contain the MQTT password. Do not log.
    var mqtt: Data = Data()

    func applying(_ writes: [SyncWrite]) throws -> RadioInventory {
        var copy = self
        for write in writes {
            switch write {
            case .owner(let user):
                copy.owner = user
                copy.longName = try PhoneAPICodec.longName(from: user)
                copy.shortName = try PhoneAPICodec.shortName(from: user)
            case .config(let kind, let body):
                switch kind {
                case .lora: copy.lora = body
                case .device: copy.device = body
                case .position: copy.position = body
                case .display: copy.display = body
                case .network: copy.network = body
                }
            case .moduleMQTT(let body):
                copy.mqtt = body
            case .channel(let raw):
                if let index = copy.channels.firstIndex(where: { channel in
                    (try? PhoneAPICodec.primaryChannel(in: [channel])) != nil
                }) {
                    copy.channels[index] = raw
                } else {
                    copy.channels = [raw]
                }
            }
        }
        return copy
    }
}

enum SyncError: Error, Equatable {
    case invalidPSK
    case channelName
    case gatewaySecret
}

extension SyncError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPSK:
            return "The fleet PSK must be 32 bytes before a channel write."
        case .channelName:
            return "The channel name must be shorter than 12 bytes."
        case .gatewaySecret:
            return "Save the gateway Wi-Fi password and the MQTT password in the Keychain before applying a gateway."
        }
    }
}

/// Compares decoded fields. A section is written only when one of its owned fields differs.
/// `set_config` still replaces that whole subsection, so the write is the merged body.
enum SyncDiff {
    static func plan(
        inventory: RadioInventory,
        profile: FleetProfile,
        role: DeviceRole,
        names: RadioNames,
        longEdited: Bool,
        shortEdited: Bool,
        psk: Data,
        function: DeviceFunction,
        wifiSSID: String,
        wifiPSK: Data,
        mqttPassword: Data
    ) throws -> SyncPlan {
        guard psk.count == 32 else { throw SyncError.invalidPSK }
        var changes: [SyncChange] = []
        var writes: [SyncWrite] = []

        let (longTarget, shortTarget) = ownerTargets(
            inventory: inventory,
            names: names,
            longEdited: longEdited,
            shortEdited: shortEdited
        )
        if longTarget != nil || shortTarget != nil {
            if let longTarget {
                changes.append(SyncChange(
                    id: "owner.long",
                    title: "Long name",
                    detail: "\(inventory.longName ?? "") → \(longTarget)"
                ))
            }
            if let shortTarget {
                changes.append(SyncChange(
                    id: "owner.short",
                    title: "Short name",
                    detail: "\(inventory.shortName ?? "") → \(shortTarget)"
                ))
            }
            let user = try PhoneAPICodec.userMessage(
                merging: inventory.owner,
                longName: longTarget,
                shortName: shortTarget
            )
            writes.append(.owner(user))
        }

        let loraFields = try PhoneAPICodec.parse(inventory.lora)
        var loraChanges: [SyncChange] = []
        noteBool(&loraChanges, id: "lora.usePreset", title: "LoRa use preset", field: 1, fields: loraFields, desired: profile.lora.usePreset)
        noteExact(
            &loraChanges,
            id: "lora.modemPreset",
            title: "LoRa preset",
            radio: PhoneAPICodec.numeric(loraFields, 2),
            desired: modemValue(profile.lora.modemPreset),
            label: modemLabel
        )
        noteExact(
            &loraChanges,
            id: "lora.region",
            title: "LoRa region",
            radio: PhoneAPICodec.numeric(loraFields, 7),
            desired: regionValue(profile.lora.region),
            label: regionLabel
        )
        noteExact(
            &loraChanges,
            id: "lora.slot",
            title: "Frequency slot",
            radio: PhoneAPICodec.numeric(loraFields, 11),
            desired: UInt64(profile.lora.frequencySlot),
            label: { String($0) }
        )
        noteExact(
            &loraChanges,
            id: "lora.hop",
            title: "Hop limit",
            radio: PhoneAPICodec.numeric(loraFields, 8),
            desired: UInt64(profile.lora.hopLimit),
            label: { String($0) }
        )
        noteBool(&loraChanges, id: "lora.tx", title: "Transmit", field: 9, fields: loraFields, desired: profile.lora.txEnabled)
        noteBool(&loraChanges, id: "lora.ignoreMQTT", title: "Ignore MQTT", field: 104, fields: loraFields, desired: profile.lora.ignoreMQTT)
        noteBool(&loraChanges, id: "lora.config_ok_to_mqtt", title: "Ok to MQTT", field: 105, fields: loraFields, desired: profile.lora.configOkToMQTT)
        if !loraChanges.isEmpty {
            changes.append(contentsOf: loraChanges)
            writes.append(.config(.lora, try PhoneAPICodec.loraConfig(merging: inventory.lora, settings: profile.lora)))
        }

        let deviceFields = try PhoneAPICodec.parse(inventory.device)
        var deviceChanges: [SyncChange] = []
        noteExact(
            &deviceChanges,
            id: "device.role",
            title: "Device role",
            radio: PhoneAPICodec.numeric(deviceFields, 1),
            desired: roleValue(role),
            label: roleLabel
        )
        noteExact(
            &deviceChanges,
            id: "device.rebroadcast",
            title: "Rebroadcast",
            radio: PhoneAPICodec.numeric(deviceFields, 6),
            desired: rebroadcastValue(profile.device.rebroadcastMode),
            label: rebroadcastLabel
        )
        let desiredZone = profile.device.timezone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !desiredZone.isEmpty {
            let radioZone = PhoneAPICodec.textValue(deviceFields, 11)
            if radioZone != desiredZone {
                deviceChanges.append(SyncChange(
                    id: "device.tzdef",
                    title: "Timezone",
                    detail: "\(radioZone) → \(desiredZone)"
                ))
            }
        }
        if !deviceChanges.isEmpty {
            changes.append(contentsOf: deviceChanges)
            writes.append(.config(.device, try PhoneAPICodec.deviceConfig(
                merging: inventory.device,
                role: role,
                settings: profile.device
            )))
        }

        let positionFields = try PhoneAPICodec.parse(inventory.position)
        var positionChanges: [SyncChange] = []
        noteBool(
            &positionChanges,
            id: "position.smart",
            title: "Smart position",
            field: 2,
            fields: positionFields,
            desired: profile.position.smartPosition
        )
        let flags = UInt32(truncatingIfNeeded: PhoneAPICodec.numeric(positionFields, 7))
        noteBit(&positionChanges, id: "position.altitude", title: "Altitude", flags: flags, bit: PhoneAPICodec.altitudeBit, desired: profile.position.flags.altitude)
        noteBit(&positionChanges, id: "position.altitudeMSL", title: "Altitude MSL", flags: flags, bit: PhoneAPICodec.altitudeMSLBit, desired: profile.position.flags.altitudeMSL)
        noteBit(&positionChanges, id: "position.geoidal", title: "Geoidal separation", flags: flags, bit: PhoneAPICodec.geoidalBit, desired: profile.position.flags.geoidalSeparation)
        noteExact(
            &positionChanges,
            id: "position.gps",
            title: "GPS",
            radio: PhoneAPICodec.numeric(positionFields, 13),
            desired: gpsValue(profile.position.gpsMode),
            label: gpsLabel
        )
        if !positionChanges.isEmpty {
            changes.append(contentsOf: positionChanges)
            writes.append(.config(.position, try PhoneAPICodec.positionConfig(merging: inventory.position, settings: profile.position)))
        }

        let displayFields = try PhoneAPICodec.parse(inventory.display)
        let radioUnits = PhoneAPICodec.numeric(displayFields, 6)
        let desiredUnits: UInt64 = profile.display.units == .imperial ? 1 : 0
        if radioUnits != desiredUnits {
            changes.append(SyncChange(
                id: "display.units",
                title: "Display units",
                detail: "\(unitsLabel(radioUnits)) → \(unitsLabel(desiredUnits))"
            ))
            writes.append(.config(.display, try PhoneAPICodec.displayConfig(merging: inventory.display, settings: profile.display)))
        }

        let existingChannel = try PhoneAPICodec.primaryChannel(in: inventory.channels)
        var channelChanges: [SyncChange] = []
        let channelParsed = try PhoneAPICodec.parse(existingChannel ?? Data())
        let settingFields = try PhoneAPICodec.bytes(channelParsed, 2).map { try PhoneAPICodec.parse($0) } ?? []
        let moduleFields = try PhoneAPICodec.bytes(settingFields, 7).map { try PhoneAPICodec.parse($0) } ?? []
        let radioName = PhoneAPICodec.textValue(settingFields, 3)
        if radioName != profile.channel.name {
            channelChanges.append(SyncChange(
                id: "channel.name",
                title: "Channel name",
                detail: "\(radioName) → \(profile.channel.name)"
            ))
        }
        let radioPSK = PhoneAPICodec.bytes(settingFields, 2) ?? Data()
        if radioPSK != psk {
            channelChanges.append(SyncChange(id: "channel.psk", title: "Channel key", detail: "differs"))
        }
        noteBool(&channelChanges, id: "channel.uplink", title: "Channel uplink", field: 5, fields: settingFields, desired: profile.channel.uplinkEnabled)
        noteBool(&channelChanges, id: "channel.downlink", title: "Channel downlink", field: 6, fields: settingFields, desired: profile.channel.downlinkEnabled)
        let desiredPrecision = profile.channel.preciseLocation ? PhoneAPICodec.preciseLocationBits : PhoneAPICodec.coarseLocationBits
        noteExact(
            &channelChanges,
            id: "channel.precision",
            title: "Location precision",
            radio: PhoneAPICodec.numeric(moduleFields, 1),
            desired: desiredPrecision,
            label: { String($0) }
        )
        if PhoneAPICodec.numeric(channelParsed, 3) != 1 {
            channelChanges.append(SyncChange(
                id: "channel.role",
                title: "Channel role",
                detail: "\(PhoneAPICodec.numeric(channelParsed, 3)) → 1"
            ))
        }
        if !channelChanges.isEmpty {
            changes.append(contentsOf: channelChanges)
            do {
                let channel = try PhoneAPICodec.mergedPrimaryChannel(
                    existing: existingChannel,
                    name: profile.channel.name,
                    psk: psk,
                    uplink: profile.channel.uplinkEnabled,
                    downlink: profile.channel.downlinkEnabled,
                    preciseLocation: profile.channel.preciseLocation
                )
                writes.append(.channel(channel))
            } catch PhoneAPICodec.CodecError.channelNameTooLong {
                throw SyncError.channelName
            }
        }

        let mqttFields = try PhoneAPICodec.parse(inventory.mqtt)
        if function == .gateway {
            guard !wifiSSID.isEmpty, !wifiPSK.isEmpty, !mqttPassword.isEmpty else { throw SyncError.gatewaySecret }
            let networkFields = try PhoneAPICodec.parse(inventory.network)
            var networkChanges: [SyncChange] = []
            noteBool(&networkChanges, id: "network.wifiEnabled", title: "Wi-Fi", field: 1, fields: networkFields, desired: true)
            let radioSSID = PhoneAPICodec.textValue(networkFields, 3)
            if radioSSID != wifiSSID {
                networkChanges.append(SyncChange(id: "network.wifiSSID", title: "Wi-Fi SSID", detail: "\(radioSSID) → \(wifiSSID)"))
            }
            noteSecret(&networkChanges, id: "network.wifiPsk", title: "Wi-Fi password", radio: PhoneAPICodec.bytes(networkFields, 4) ?? Data(), desired: wifiPSK)
            if !networkChanges.isEmpty {
                changes.append(contentsOf: networkChanges)
                writes.append(.config(.network, try PhoneAPICodec.networkConfig(merging: inventory.network, ssid: wifiSSID, psk: wifiPSK)))
            }
            var mqttChanges: [SyncChange] = []
            noteBool(&mqttChanges, id: "mqtt.enabled", title: "MQTT", field: 1, fields: mqttFields, desired: true)
            noteText(&mqttChanges, id: "mqtt.address", title: "MQTT address", radio: PhoneAPICodec.textValue(mqttFields, 2), desired: profile.mqtt.address)
            noteText(&mqttChanges, id: "mqtt.username", title: "MQTT username", radio: PhoneAPICodec.textValue(mqttFields, 3), desired: profile.mqtt.username)
            noteSecret(&mqttChanges, id: "mqtt.password", title: "MQTT password", radio: PhoneAPICodec.bytes(mqttFields, 4) ?? Data(), desired: mqttPassword)
            noteBool(&mqttChanges, id: "mqtt.encryption", title: "MQTT encryption", field: 5, fields: mqttFields, desired: false)
            noteBool(&mqttChanges, id: "mqtt.json", title: "MQTT JSON", field: 6, fields: mqttFields, desired: false)
            noteBool(&mqttChanges, id: "mqtt.tls", title: "MQTT TLS", field: 7, fields: mqttFields, desired: false)
            noteText(&mqttChanges, id: "mqtt.root", title: "MQTT root", radio: PhoneAPICodec.textValue(mqttFields, 8), desired: profile.mqtt.root)
            noteBool(&mqttChanges, id: "mqtt.proxy", title: "MQTT proxy", field: 9, fields: mqttFields, desired: false)
            noteBool(&mqttChanges, id: "mqtt.mapReporting", title: "MQTT map reporting", field: 10, fields: mqttFields, desired: false)
            if !mqttChanges.isEmpty {
                changes.append(contentsOf: mqttChanges)
                writes.append(.moduleMQTT(try PhoneAPICodec.mqttConfig(
                    merging: inventory.mqtt,
                    enabled: true,
                    address: profile.mqtt.address,
                    username: profile.mqtt.username,
                    password: mqttPassword,
                    root: profile.mqtt.root,
                    clearBridgeFlags: true
                )))
            }
        } else {
            var mqttChanges: [SyncChange] = []
            noteBool(&mqttChanges, id: "mqtt.enabled", title: "MQTT", field: 1, fields: mqttFields, desired: false)
            if !mqttChanges.isEmpty {
                changes.append(contentsOf: mqttChanges)
                writes.append(.moduleMQTT(try PhoneAPICodec.mqttConfig(
                    merging: inventory.mqtt,
                    enabled: false,
                    address: nil,
                    username: nil,
                    password: nil,
                    root: nil,
                    clearBridgeFlags: false
                )))
            }
        }

        return SyncPlan(
            changes: changes,
            writes: writes,
            writtenLongName: longTarget,
            writtenShortName: shortTarget
        )
    }

    /// A blank field, or a field the user did not edit, does not change the owner record.
    /// An edited non-blank field is written only when it differs from the radio.
    static func ownerTargets(
        inventory: RadioInventory,
        names: RadioNames,
        longEdited: Bool,
        shortEdited: Bool
    ) -> (String?, String?) {
        let longTarget = longEdited ? names.longName.flatMap { $0 == inventory.longName ? nil : $0 } : nil
        let shortTarget = shortEdited ? names.shortName.flatMap { $0 == inventory.shortName ? nil : $0 } : nil
        return (longTarget, shortTarget)
    }

    /// Nil when the field diff matches the role-only fixture and the other guards.
    /// The failure string is a short label and never includes key bytes.
    static func selfCheck() -> String? {
        do {
            return try runSelfCheck()
        } catch {
            return "sync-diff"
        }
    }

    // MARK: - Field notes

    private static func noteText(
        _ bucket: inout [SyncChange],
        id: String,
        title: String,
        radio: String,
        desired: String
    ) {
        guard radio != desired else { return }
        bucket.append(SyncChange(id: id, title: title, detail: "\(radio) → \(desired)"))
    }

    /// Password rows never include either value.
    private static func noteSecret(
        _ bucket: inout [SyncChange],
        id: String,
        title: String,
        radio: Data,
        desired: Data
    ) {
        guard radio != desired else { return }
        bucket.append(SyncChange(id: id, title: title, detail: "•••• changed"))
    }

    private static func noteBool(
        _ bucket: inout [SyncChange],
        id: String,
        title: String,
        field: Int,
        fields: [PhoneAPICodec.Field],
        desired: Bool
    ) {
        let radio = PhoneAPICodec.numeric(fields, field) != 0
        guard radio != desired else { return }
        bucket.append(SyncChange(id: id, title: title, detail: "\(onOff(radio)) → \(onOff(desired))"))
    }

    private static func noteBit(
        _ bucket: inout [SyncChange],
        id: String,
        title: String,
        flags: UInt32,
        bit: UInt32,
        desired: Bool
    ) {
        let radio = flags & bit != 0
        guard radio != desired else { return }
        bucket.append(SyncChange(id: id, title: title, detail: "\(onOff(radio)) → \(onOff(desired))"))
    }

    private static func noteExact(
        _ bucket: inout [SyncChange],
        id: String,
        title: String,
        radio: UInt64,
        desired: UInt64,
        label: (UInt64) -> String
    ) {
        guard radio != desired else { return }
        bucket.append(SyncChange(id: id, title: title, detail: "\(label(radio)) → \(label(desired))"))
    }

    private static func onOff(_ value: Bool) -> String { value ? "on" : "off" }

    private static func roleValue(_ role: DeviceRole) -> UInt64 {
        switch role {
        case .client: return 0
        case .tak: return 7
        case .takTracker: return 10
        case .clientBase: return 12
        }
    }

    private static func roleLabel(_ value: UInt64) -> String {
        switch value {
        case 0: return "CLIENT"
        case 7: return "TAK"
        case 10: return "TAK_TRACKER"
        case 12: return "CLIENT_BASE"
        default: return String(value)
        }
    }

    private static func rebroadcastValue(_ mode: RebroadcastMode) -> UInt64 {
        switch mode {
        case .all: return 0
        case .localOnly: return 2
        case .none: return 4
        }
    }

    private static func rebroadcastLabel(_ value: UInt64) -> String {
        switch value {
        case 0: return "ALL"
        case 1: return "ALL_SKIP_DECODING"
        case 2: return "LOCAL_ONLY"
        case 3: return "KNOWN_ONLY"
        case 4: return "NONE"
        case 5: return "CORE_PORTNUMS_ONLY"
        default: return String(value)
        }
    }

    private static func modemValue(_ preset: ModemPreset) -> UInt64 {
        switch preset {
        case .longFast: return 0
        case .mediumFast: return 4
        case .shortTurbo: return 8
        }
    }

    private static func modemLabel(_ value: UInt64) -> String {
        switch value {
        case 0: return "LONG_FAST"
        case 4: return "MEDIUM_FAST"
        case 6: return "SHORT_FAST"
        case 8: return "SHORT_TURBO"
        default: return String(value)
        }
    }

    private static func regionValue(_ region: LoRaRegion) -> UInt64 {
        switch region {
        case .unset: return 0
        case .us: return 1
        case .eu868: return 3
        }
    }

    private static func regionLabel(_ value: UInt64) -> String {
        switch value {
        case 0: return "UNSET"
        case 1: return "US"
        case 2: return "EU_433"
        case 3: return "EU_868"
        default: return String(value)
        }
    }

    private static func gpsValue(_ mode: GPSMode) -> UInt64 {
        switch mode {
        case .disabled: return 0
        case .enabled: return 1
        case .notPresent: return 2
        }
    }

    private static func gpsLabel(_ value: UInt64) -> String {
        switch value {
        case 0: return "DISABLED"
        case 1: return "ENABLED"
        case 2: return "NOT_PRESENT"
        default: return String(value)
        }
    }

    private static func unitsLabel(_ value: UInt64) -> String {
        switch value {
        case 0: return "METRIC"
        case 1: return "IMPERIAL"
        default: return String(value)
        }
    }

    // MARK: - Self-check

    /// Radio matches the TAK profile except `device.role`, encoded the way firmware does:
    /// shuffled fields, explicit zeros, fixed32 where we emit varints, and unsorted channel settings.
    /// A byte compare of those bodies is dirty. The field diff must be exactly `device.role`.
    private static func runSelfCheck() throws -> String? {
        let profile = BuiltInProfiles.takTracker()
        // 0x5A repeated is an encoder fixture, not a fleet key. Do not print it.
        let psk = Data(repeating: 0x5A, count: 32)
        let zone = Data((profile.device.timezone ?? "").utf8)
        let noisy = RadioInventory(
            lora: RawProto.message([
                (105, .varint(1)),
                (11, .varint(50)),
                (8, .varint(3)),
                (7, .fixed32(1)),
                (9, .varint(1)),
                (2, .varint(8)),
                (3, .varint(250)),
                (103, .varint(0)),
                (1, .varint(1)),
            ]),
            device: RawProto.message([
                (11, .bytes(zone)),
                (7, .varint(0)),
                (6, .varint(0)),
                (1, .varint(10)),
            ]),
            position: RawProto.message([
                (1, .varint(900)),
                (13, .varint(1)),
                (7, .fixed32(5)),
                (4, .varint(0)),
                (2, .varint(1)),
            ]),
            display: RawProto.message([
                (1, .varint(60)),
                (5, .varint(0)),
                (6, .fixed32(1)),
            ]),
            owner: try PhoneAPICodec.userMessage(merging: Data(), longName: "Tracker", shortName: "Trk"),
            longName: "Tracker",
            shortName: "Trk",
            channels: [noisyChannel(psk: psk)],
            observedConfigFields: [1, 2, 3, 4, 5, 6, 7, 8],
            observedModuleFields: [1]
        )

        let mergedLora = try PhoneAPICodec.loraConfig(merging: noisy.lora, settings: profile.lora)
        guard try mergedLora != PhoneAPICodec.canonical(noisy.lora) else { return "byte-lora" }
        let mergedPosition = try PhoneAPICodec.positionConfig(merging: noisy.position, settings: profile.position)
        guard try mergedPosition != PhoneAPICodec.canonical(noisy.position) else { return "byte-position" }
        let mergedDisplay = try PhoneAPICodec.displayConfig(merging: noisy.display, settings: profile.display)
        guard try mergedDisplay != PhoneAPICodec.canonical(noisy.display) else { return "byte-display" }
        let existingChannel = try PhoneAPICodec.primaryChannel(in: noisy.channels)
        let mergedChannel = try PhoneAPICodec.mergedPrimaryChannel(
            existing: existingChannel,
            name: profile.channel.name,
            psk: psk,
            uplink: profile.channel.uplinkEnabled,
            downlink: profile.channel.downlinkEnabled,
            preciseLocation: profile.channel.preciseLocation
        )
        guard let existingChannel, try mergedChannel != PhoneAPICodec.canonical(existingChannel) else {
            return "byte-channel"
        }

        let plan = try SyncDiff.plan(
            inventory: noisy,
            profile: profile,
            role: .tak,
            names: RadioNames(longName: "Stale", shortName: "Old"),
            longEdited: false,
            shortEdited: false,
            psk: psk,
            function: .tracker,
            wifiSSID: "",
            wifiPSK: Data(),
            mqttPassword: Data()
        )
        guard plan.changes.map(\.id) == ["device.role"] else { return "role-only" }
        guard plan.changes.first?.detail == "TAK_TRACKER → TAK" else { return "role-detail" }
        guard plan.writes.count == 1, case .config(.device, _) = plan.writes.first else { return "role-write" }
        guard plan.progress.debugLines == ["device.role: TAK_TRACKER → TAK"] else { return "debug-line" }
        guard plan.summary == "1 setting will change" else { return "summary" }

        let writing = ApplyStepRow.rows(state: .applyingChanges, progress: plan.progress)
        guard writing.map(\.id) == ["handshake", "psk", "compare", "device.role", "reboot", "verify"] else {
            return "rows"
        }
        guard writing.first(where: { $0.id == "device.role" })?.detail == "TAK_TRACKER → TAK" else {
            return "rows-detail"
        }
        guard writing.first(where: { $0.id == "device.role" })?.status == .current else { return "rows-current" }

        let updated = try noisy.applying(plan.writes)
        let again = try SyncDiff.plan(
            inventory: updated,
            profile: profile,
            role: .tak,
            names: RadioNames(longName: nil, shortName: nil),
            longEdited: false,
            shortEdited: false,
            psk: psk,
            function: .tracker,
            wifiSSID: "",
            wifiPSK: Data(),
            mqttPassword: Data()
        )
        guard again.changes.isEmpty, again.writes.isEmpty else { return "second-plan" }
        let done = ApplyStepRow.rows(state: .verifying, progress: again.progress)
        guard done.map(\.id) == ["handshake", "psk", "compare", "verify"] else { return "rows-empty" }

        let named = try SyncDiff.plan(
            inventory: noisy,
            profile: profile,
            role: .tak,
            names: RadioNames(longName: "Koala", shortName: nil),
            longEdited: true,
            shortEdited: false,
            psk: psk,
            function: .tracker,
            wifiSSID: "",
            wifiPSK: Data(),
            mqttPassword: Data()
        )
        guard named.changes.map(\.id) == ["owner.long", "device.role"] else { return "long-and-role" }
        guard named.writes.count == 2 else { return "long-and-role-writes" }

        let metric = BuiltInProfiles.takTracker(displayUnits: .metric)
        let explicitZero = RadioInventory(
            lora: try PhoneAPICodec.loraConfig(merging: Data(), settings: metric.lora),
            device: try PhoneAPICodec.deviceConfig(merging: Data(), role: .tak, settings: metric.device),
            position: try PhoneAPICodec.positionConfig(merging: Data(), settings: metric.position),
            display: RawProto.message([
                (1, .varint(60)),
                (6, .varint(0)),
            ]),
            owner: try PhoneAPICodec.userMessage(merging: Data(), longName: "Tracker", shortName: "Trk"),
            longName: "Tracker",
            shortName: "Trk",
            channels: [try PhoneAPICodec.channelMessage(
                name: metric.channel.name,
                psk: psk,
                uplink: true,
                downlink: true,
                preciseLocation: true,
                channelID: 0x11223344
            )],
            observedConfigFields: [1, 2, 5, 6],
            observedModuleFields: []
        )
        let zeroDisplay = try PhoneAPICodec.displayConfig(merging: explicitZero.display, settings: metric.display)
        guard try zeroDisplay != PhoneAPICodec.canonical(explicitZero.display) else { return "zero-byte" }
        let zeroPlan = try SyncDiff.plan(
            inventory: explicitZero,
            profile: metric,
            role: .tak,
            names: RadioNames(longName: nil, shortName: nil),
            longEdited: true,
            shortEdited: true,
            psk: psk,
            function: .tracker,
            wifiSSID: "",
            wifiPSK: Data(),
            mqttPassword: Data()
        )
        guard zeroPlan.changes.isEmpty else { return "zero-units" }

        if let problem = try trackerMQTTCheck(profile: profile, psk: psk) { return problem }
        if let problem = try rebroadcastCheck(profile: profile, psk: psk) { return problem }
        if let problem = try gatewayCheck(profile: profile, psk: psk) { return problem }
        return nil
    }

    /// A radio that matches the TAK profile except Ok to MQTT, Ignore MQTT, and channel uplink/downlink.
    private static func trackerMQTTCheck(profile: FleetProfile, psk: Data) throws -> String? {
        var drifted = profile.lora
        drifted.ignoreMQTT = true
        drifted.configOkToMQTT = false
        let inventory = RadioInventory(
            lora: try PhoneAPICodec.loraConfig(merging: Data(), settings: drifted),
            device: try PhoneAPICodec.deviceConfig(merging: Data(), role: .takTracker, settings: profile.device),
            position: try PhoneAPICodec.positionConfig(merging: Data(), settings: profile.position),
            display: try PhoneAPICodec.displayConfig(merging: Data(), settings: profile.display),
            owner: try PhoneAPICodec.userMessage(merging: Data(), longName: "Tracker", shortName: "Trk"),
            longName: "Tracker",
            shortName: "Trk",
            channels: [try PhoneAPICodec.channelMessage(
                name: profile.channel.name,
                psk: psk,
                uplink: false,
                downlink: false,
                preciseLocation: true,
                channelID: 0x11223344
            )],
            observedConfigFields: [1, 2, 5, 6],
            observedModuleFields: [],
            mqtt: RawProto.message([(1, .varint(1))])
        )
        let plan = try SyncDiff.plan(
            inventory: inventory,
            profile: profile,
            role: .takTracker,
            names: RadioNames(longName: nil, shortName: nil),
            longEdited: false,
            shortEdited: false,
            psk: psk,
            function: .tracker,
            wifiSSID: "",
            wifiPSK: Data(),
            mqttPassword: Data()
        )
        let ids = plan.changes.map(\.id)
        for required in ["lora.config_ok_to_mqtt", "lora.ignoreMQTT", "channel.uplink", "channel.downlink", "mqtt.enabled"] {
            guard ids.contains(required) else { return "tracker-missing" }
        }
        guard plan.writes.contains(where: { if case .config(.lora, _) = $0 { return true }; return false }) else { return "tracker-lora" }
        guard plan.writes.contains(where: { if case .channel = $0 { return true }; return false }) else { return "tracker-channel" }
        guard plan.writes.contains(where: { if case .moduleMQTT = $0 { return true }; return false }) else { return "tracker-mqtt" }
        guard !plan.writes.contains(where: { if case .config(.network, _) = $0 { return true }; return false }) else { return "tracker-network" }
        let updated = try inventory.applying(plan.writes)
        let again = try SyncDiff.plan(
            inventory: updated,
            profile: profile,
            role: .takTracker,
            names: RadioNames(longName: nil, shortName: nil),
            longEdited: false,
            shortEdited: false,
            psk: psk,
            function: .tracker,
            wifiSSID: "",
            wifiPSK: Data(),
            mqttPassword: Data()
        )
        guard again.changes.isEmpty, again.writes.isEmpty else { return "tracker-second" }
        return nil
    }

    /// CORE_PORTNUMS_ONLY (protobuf 5) drops ATAK_PLUGIN. Trackers and gateways both write ALL.
    private static func rebroadcastCheck(profile: FleetProfile, psk: Data) throws -> String? {
        var deviceFields = try PhoneAPICodec.parse(
            PhoneAPICodec.deviceConfig(merging: Data(), role: .takTracker, settings: profile.device)
        )
        PhoneAPICodec.upsertVarint(&deviceFields, 6, 5, force: true)
        let inventory = RadioInventory(
            lora: try PhoneAPICodec.loraConfig(merging: Data(), settings: profile.lora),
            device: PhoneAPICodec.serialize(deviceFields),
            position: try PhoneAPICodec.positionConfig(merging: Data(), settings: profile.position),
            display: try PhoneAPICodec.displayConfig(merging: Data(), settings: profile.display),
            owner: try PhoneAPICodec.userMessage(merging: Data(), longName: "Tracker", shortName: "Trk"),
            longName: "Tracker",
            shortName: "Trk",
            channels: [try PhoneAPICodec.channelMessage(
                name: profile.channel.name,
                psk: psk,
                uplink: true,
                downlink: true,
                preciseLocation: true,
                channelID: 0x11223344
            )],
            observedConfigFields: [1, 2, 5, 6],
            observedModuleFields: []
        )
        let plan = try SyncDiff.plan(
            inventory: inventory,
            profile: profile,
            role: .takTracker,
            names: RadioNames(longName: nil, shortName: nil),
            longEdited: false,
            shortEdited: false,
            psk: psk,
            function: .tracker,
            wifiSSID: "",
            wifiPSK: Data(),
            mqttPassword: Data()
        )
        guard plan.changes.map(\.id) == ["device.rebroadcast"] else { return "rebroadcast-id" }
        guard plan.changes.first?.detail == "CORE_PORTNUMS_ONLY → ALL" else { return "rebroadcast-detail" }
        guard plan.writes.count == 1, case .config(.device, _) = plan.writes.first else { return "rebroadcast-write" }
        let updated = try inventory.applying(plan.writes)
        let again = try SyncDiff.plan(
            inventory: updated,
            profile: profile,
            role: .takTracker,
            names: RadioNames(longName: nil, shortName: nil),
            longEdited: false,
            shortEdited: false,
            psk: psk,
            function: .tracker,
            wifiSSID: "",
            wifiPSK: Data(),
            mqttPassword: Data()
        )
        guard again.changes.isEmpty, again.writes.isEmpty else { return "rebroadcast-second" }
        let gateway = try SyncDiff.plan(
            inventory: inventory,
            profile: profile,
            role: .client,
            names: RadioNames(longName: nil, shortName: nil),
            longEdited: false,
            shortEdited: false,
            psk: psk,
            function: .gateway,
            wifiSSID: "OTS-Shop",
            wifiPSK: Data("wifi-secret".utf8),
            mqttPassword: Data("mqtt-secret".utf8)
        )
        guard gateway.changes.contains(where: { $0.id == "device.rebroadcast" && $0.detail == "CORE_PORTNUMS_ONLY → ALL" }) else {
            return "rebroadcast-gateway"
        }
        return nil
    }

    /// Gateway writes network and the MQTT module in one plan. Passwords stay out of the debug list.
    private static func gatewayCheck(profile: FleetProfile, psk: Data) throws -> String? {
        let wifiPSK = Data("wifi-secret".utf8)
        let mqttPassword = Data("mqtt-secret".utf8)
        let inventory = RadioInventory(
            lora: try PhoneAPICodec.loraConfig(merging: Data(), settings: profile.lora),
            device: try PhoneAPICodec.deviceConfig(merging: Data(), role: .client, settings: profile.device),
            position: try PhoneAPICodec.positionConfig(merging: Data(), settings: profile.position),
            display: try PhoneAPICodec.displayConfig(merging: Data(), settings: profile.display),
            owner: try PhoneAPICodec.userMessage(merging: Data(), longName: "Gateway", shortName: "Gw"),
            longName: "Gateway",
            shortName: "Gw",
            channels: [try PhoneAPICodec.channelMessage(
                name: profile.channel.name,
                psk: psk,
                uplink: true,
                downlink: true,
                preciseLocation: true,
                channelID: 0x11223344
            )],
            observedConfigFields: [1, 2, 4, 5, 6],
            observedModuleFields: [1]
        )
        let plan = try SyncDiff.plan(
            inventory: inventory,
            profile: profile,
            role: .client,
            names: RadioNames(longName: nil, shortName: nil),
            longEdited: false,
            shortEdited: false,
            psk: psk,
            function: .gateway,
            wifiSSID: "OTS-Shop",
            wifiPSK: wifiPSK,
            mqttPassword: mqttPassword
        )
        let networkWrites = plan.writes.filter { if case .config(.network, _) = $0 { return true }; return false }
        let mqttWrites = plan.writes.filter { if case .moduleMQTT = $0 { return true }; return false }
        guard networkWrites.count == 1, mqttWrites.count == 1 else { return "gateway-writes" }
        guard plan.writes.count == 2 else { return "gateway-extra" }
        let lines = plan.progress.debugLines.joined(separator: "\n")
        guard !lines.contains("wifi-secret"), !lines.contains("mqtt-secret") else { return "gateway-leak" }
        guard lines.contains("network.wifiPsk: •••• changed") else { return "gateway-wifi-mask" }
        guard lines.contains("mqtt.password: •••• changed") else { return "gateway-mqtt-mask" }
        guard case .moduleMQTT(let mqttBody) = mqttWrites[0], mqttBody.range(of: mqttPassword) != nil else {
            return "gateway-mqtt-body"
        }
        guard case .config(.network, let networkBody) = networkWrites[0], networkBody.range(of: wifiPSK) != nil else {
            return "gateway-network-body"
        }
        let updated = try inventory.applying(plan.writes)
        let again = try SyncDiff.plan(
            inventory: updated,
            profile: profile,
            role: .client,
            names: RadioNames(longName: nil, shortName: nil),
            longEdited: false,
            shortEdited: false,
            psk: psk,
            function: .gateway,
            wifiSSID: "OTS-Shop",
            wifiPSK: wifiPSK,
            mqttPassword: mqttPassword
        )
        guard again.changes.isEmpty, again.writes.isEmpty else { return "gateway-second" }
        return nil
    }

    private static func noisyChannel(psk: Data) -> Data {
        let module = RawProto.message([
            (2, .varint(0)),
            (1, .varint(32)),
        ])
        let settings = RawProto.message([
            (6, .varint(1)),
            (3, .bytes(Data("TAK".utf8))),
            (7, .bytes(module)),
            (5, .varint(1)),
            (4, .fixed32(0x11223344)),
            (2, .bytes(psk)),
        ])
        return RawProto.message([
            (3, .varint(1)),
            (1, .varint(0)),
            (2, .bytes(settings)),
        ])
    }
}

/// Progress rows for one apply. Built from copied session state so the SwiftUI view stays isolated.
enum ApplyStepStatus {
    case waiting, current, done, failed
}

struct ApplyStepRow: Identifiable {
    var id: String
    var title: String
    var status: ApplyStepStatus
    var detail: String?

    static func rows(state: ApplySessionState, progress: SyncProgress?) -> [ApplyStepRow] {
        var specs: [StepSpec] = [
            StepSpec(id: "handshake", title: "Connected & handshake", detail: nil, kind: .handshake),
            StepSpec(id: "psk", title: "Fleet PSK ready", detail: nil, kind: .psk),
            StepSpec(id: "compare", title: "Compare with radio", detail: nil, kind: .compare),
        ]
        for change in progress?.changes ?? [] {
            specs.append(StepSpec(id: change.id, title: change.title, detail: change.detail, kind: .field))
        }
        if progress?.isEmpty == false {
            specs.append(StepSpec(id: "reboot", title: "Reboot", detail: nil, kind: .reboot))
        }
        specs.append(StepSpec(id: "verify", title: "Verify", detail: nil, kind: .verify))

        let failedKind = failedKind(state)
        let active = failedKind ?? activeKind(state)
        return specs.map { spec in
            let status = status(of: spec.kind, active: active, failed: failedKind, state: state)
            return ApplyStepRow(
                id: spec.id,
                title: spec.title,
                status: status,
                detail: detail(spec, status: status, state: state, progress: progress)
            )
        }
    }

    private struct StepSpec {
        var id: String
        var title: String
        var detail: String?
        var kind: Kind
    }

    private enum Kind {
        case handshake, psk, compare, field, reboot, verify
    }

    private static func rank(_ kind: Kind) -> Int {
        switch kind {
        case .handshake: return 0
        case .psk: return 1
        case .compare: return 2
        case .field: return 3
        case .reboot: return 4
        case .verify: return 5
        }
    }

    private static func activeKind(_ state: ApplySessionState) -> Kind {
        switch state {
        case .idle, .scanning, .connecting, .handshaking:
            return .handshake
        case .ensuringPSK:
            return .psk
        case .comparing:
            return .compare
        case .applyingChanges:
            return .field
        case .waitingReboot, .reconnecting:
            return .reboot
        case .verifying, .succeeded, .disconnecting, .disconnected:
            return .verify
        case .failed:
            return .handshake
        }
    }

    private static func failedKind(_ state: ApplySessionState) -> Kind? {
        guard case .failed(let failure) = state else { return nil }
        return activeKind(failure.stage)
    }

    private static func status(of kind: Kind, active: Kind, failed: Kind?, state: ApplySessionState) -> ApplyStepStatus {
        if let failed {
            if rank(kind) < rank(failed) { return .done }
            if kind == failed { return .failed }
            return .waiting
        }
        if state == .succeeded { return .done }
        if rank(kind) < rank(active) { return .done }
        if kind == active { return .current }
        return .waiting
    }

    private static func detail(
        _ spec: StepSpec,
        status: ApplyStepStatus,
        state: ApplySessionState,
        progress: SyncProgress?
    ) -> String? {
        if spec.kind == .field {
            return spec.detail
        }
        if spec.kind == .compare, let progress, status == .done || state == .succeeded {
            return progress.summary
        }
        guard status == .current || status == .failed else { return nil }
        switch state {
        case .connecting:
            return "Connecting"
        case .handshaking:
            return spec.kind == .handshake ? "PhoneAPI handshake" : nil
        case .ensuringPSK:
            return "Checking the Keychain"
        case .comparing:
            return "Reading the radio and comparing"
        case .waitingReboot:
            return "Waiting for the radio to reboot. Trackers can take a minute."
        case .reconnecting:
            return "Waiting for Bluetooth to come back, then handshake"
        case .verifying:
            return "Reading back"
        case .failed(let failure):
            return failure.message
        default:
            return nil
        }
    }
}

extension PhoneAPICodec {
    /// Primary channel, or index 0 when no channel is marked primary yet.
    static func primaryChannel(in channels: [Data]) throws -> Data? {
        var indexZero: Data?
        for raw in channels {
            let fields = try parse(raw)
            let role = varint(fields, 3) ?? 0
            let index = varint(fields, 1) ?? 0
            if role == 1 { return raw }
            if index == 0 { indexZero = raw }
        }
        return indexZero
    }
}

/// Field order is preserved. `PhoneAPICodec.serialize` sorts, which would hide the firmware fixture.
private enum RawProto {
    enum Payload {
        case varint(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    static func message(_ fields: [(Int, Payload)]) -> Data {
        var out = Data()
        for (number, payload) in fields {
            switch payload {
            case .varint(let value):
                out.append(varint(UInt64(number << 3)))
                out.append(varint(value))
            case .fixed32(let value):
                out.append(varint(UInt64((number << 3) | 5)))
                out.append(UInt8(value & 0xff))
                out.append(UInt8((value >> 8) & 0xff))
                out.append(UInt8((value >> 16) & 0xff))
                out.append(UInt8((value >> 24) & 0xff))
            case .bytes(let data):
                out.append(varint(UInt64((number << 3) | 2)))
                out.append(varint(UInt64(data.count)))
                out.append(data)
            }
        }
        return out
    }

    private static func varint(_ value: UInt64) -> Data {
        var number = value
        var out = Data()
        while true {
            var byte = UInt8(number & 0x7f)
            number >>= 7
            if number != 0 {
                byte |= 0x80
                out.append(byte)
            } else {
                out.append(byte)
                return out
            }
        }
    }
}
