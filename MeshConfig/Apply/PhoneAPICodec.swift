import Foundation

/// PhoneAPI wire codec for the admin apply path.
///
/// Field numbers match meshtastic/protobufs commit `ad0bf31e82886d794334dcc62abb80da862a8ec7`
/// (master, 2026-09-25): `mesh.proto`, `admin.proto`, `config.proto`, `channel.proto`, `portnums.proto`.
/// This is a subset encoder, not a generated SwiftProtobuf module. Unknown fields inside a config
/// body are preserved so `set_config` does not wipe `tx_enabled`, hop limit, or screen timeout.
///
/// Nothing in here logs key bytes, session passkeys, or full admin payloads.
enum PhoneAPICodec {
    static let configOnlyNonce: UInt32 = 69420
    static let nodesOnlyNonce: UInt32 = 69421
    static let adminPort: UInt64 = 6
    static let routingPort: UInt64 = 5
    static let reliablePriority: UInt64 = 70
    static let passkeyField = 101
    static let preciseLocationBits: UInt64 = 32
    static let coarseLocationBits: UInt64 = 14
    static let rebootDelaySeconds: UInt64 = 2
    static let maxChannelNameBytes = 11

    static let altitudeBit: UInt32 = 0x0001
    static let altitudeMSLBit: UInt32 = 0x0002
    static let geoidalBit: UInt32 = 0x0004

    /// Public Meshtastic default channel key from `channel.proto`. Not a fleet secret.
    private static let documentedDefaultPSK: [UInt8] = [
        0xd4, 0xf1, 0xbb, 0x3a, 0x20, 0x29, 0x07, 0x59,
        0xf0, 0xbc, 0xff, 0xab, 0xcf, 0x4e, 0x69, 0x01,
    ]

    enum CodecError: Error {
        case malformed
        case channelNameTooLong
    }

    enum Value {
        case varint(UInt64)
        case fixed64(Data)
        case bytes(Data)
        case fixed32(UInt32)
    }

    struct Field {
        var number: Int
        var value: Value
    }

    enum ConfigKind: Equatable {
        case device
        case position
        case display
        case lora
    }

    struct ConfigSlice: Equatable {
        var kind: ConfigKind
        var body: Data
    }

    struct ParsedChannel: Equatable {
        var index: Int
        var role: Int
        var name: String?
        var nonDefaultPSK: Bool
        var preciseLocation: Bool
        /// Original Channel message. May contain the channel PSK. Do not log it.
        var raw: Data
    }

    struct ParsedAdmin: Equatable {
        var passkey: Data?
        var config: ConfigSlice?
        var channel: ParsedChannel?
        /// Raw `User` from `get_owner_response`. Kept so `set_owner` can preserve fields this app does not edit.
        var owner: Data?
    }

    enum Inbound: Equatable {
        case myNode(UInt32)
        case config(ConfigSlice)
        /// Config oneof this app reads but does not write (power, network, bluetooth, security). Body is not retained.
        case otherConfig(field: Int)
        /// ModuleConfig oneof field number. Body is not retained (MQTT configs can hold passwords).
        case moduleConfig(field: Int)
        case channel(ParsedChannel)
        case configComplete(UInt32)
        case routing(requestID: UInt32, error: UInt64?)
        case admin(requestID: UInt32, message: ParsedAdmin)
        case notice(String)
        case other
    }

    // MARK: - Encode

    static func wantConfig(nonce: UInt32) -> Data {
        serialize([Field(number: 3, value: .varint(UInt64(nonce)))])
    }

    static func getOwnerAdmin(passkey: Data? = nil) -> Data {
        var fields = [Field(number: 3, value: .varint(1))]
        if let passkey, passkey.count == 8 {
            fields.append(Field(number: passkeyField, value: .bytes(passkey)))
        }
        return serialize(fields)
    }

    static func setOwnerAdmin(user: Data, passkey: Data) -> Data {
        var fields: [Field] = []
        upsertBytes(&fields, 32, user)
        if passkey.count == 8 {
            upsertBytes(&fields, passkeyField, passkey)
        }
        return serialize(fields)
    }

    /// Replaces only the name fields that are non-nil. A nil field is left as it was on the radio.
    /// Empty strings are ignored so a blank Apply field cannot clear a name.
    static func userMessage(merging existing: Data, longName: String?, shortName: String?) throws -> Data {
        var fields = try parse(existing)
        if let longName, !longName.isEmpty {
            upsertBytes(&fields, 2, Data(longName.utf8))
        }
        if let shortName, !shortName.isEmpty {
            upsertBytes(&fields, 3, Data(shortName.utf8))
        }
        return serialize(fields)
    }

    static func longName(from user: Data) throws -> String? {
        try text(from: user, field: 2)
    }

    static func shortName(from user: Data) throws -> String? {
        try text(from: user, field: 3)
    }

    static func beginEditAdmin(passkey: Data) -> Data {
        editTransactionAdmin(field: 64, passkey: passkey)
    }

    static func commitEditAdmin(passkey: Data) -> Data {
        editTransactionAdmin(field: 65, passkey: passkey)
    }

    static func getConfigAdmin(kind: UInt64, passkey: Data?) -> Data {
        var fields: [Field] = []
        upsertVarint(&fields, 5, kind, force: true)
        if let passkey, passkey.count == 8 {
            upsertBytes(&fields, passkeyField, passkey)
        }
        return serialize(fields)
    }

    static func getChannelAdmin(index: Int, passkey: Data?) -> Data {
        var fields: [Field] = []
        // Request is index + 1 so protobuf does not omit channel 0.
        upsertVarint(&fields, 1, UInt64(index + 1), force: true)
        if let passkey, passkey.count == 8 {
            upsertBytes(&fields, passkeyField, passkey)
        }
        return serialize(fields)
    }

    static func setConfigAdmin(config: Data, passkey: Data) -> Data {
        var fields: [Field] = []
        upsertBytes(&fields, 34, config)
        if passkey.count == 8 {
            upsertBytes(&fields, passkeyField, passkey)
        }
        return serialize(fields)
    }

    static func setChannelAdmin(channel: Data, passkey: Data) -> Data {
        var fields: [Field] = []
        upsertBytes(&fields, 33, channel)
        if passkey.count == 8 {
            upsertBytes(&fields, passkeyField, passkey)
        }
        return serialize(fields)
    }

    static func rebootAdmin(seconds: UInt64, passkey: Data) -> Data {
        var fields: [Field] = []
        upsertVarint(&fields, 97, seconds, force: true)
        if passkey.count == 8 {
            upsertBytes(&fields, passkeyField, passkey)
        }
        return serialize(fields)
    }

    static func loraConfig(merging existing: Data, settings: LoRaSettings) throws -> Data {
        var fields = try parse(existing)
        upsertVarint(&fields, 1, settings.usePreset ? 1 : 0)
        upsertVarint(&fields, 2, modemPresetValue(settings.modemPreset))
        upsertVarint(&fields, 7, regionValue(settings.region))
        upsertVarint(&fields, 11, UInt64(settings.frequencySlot))
        upsertVarint(&fields, 104, settings.ignoreMQTT ? 1 : 0)
        return serialize(fields)
    }

    static func deviceConfig(merging existing: Data, role: DeviceRole, settings: DeviceSettings) throws -> Data {
        var fields = try parse(existing)
        upsertVarint(&fields, 1, roleValue(role), force: true)
        upsertVarint(&fields, 6, rebroadcastValue(settings.rebroadcastMode))
        if let timezone = settings.timezone?.trimmingCharacters(in: .whitespacesAndNewlines), !timezone.isEmpty {
            upsertBytes(&fields, 11, Data(timezone.utf8))
        }
        return serialize(fields)
    }

    static func positionConfig(merging existing: Data, settings: PositionSettings) throws -> Data {
        var fields = try parse(existing)
        upsertVarint(&fields, 2, settings.smartPosition ? 1 : 0)
        var flags = UInt32(truncatingIfNeeded: varint(fields, 7) ?? 0)
        setBit(&flags, altitudeBit, settings.flags.altitude)
        setBit(&flags, altitudeMSLBit, settings.flags.altitudeMSL)
        setBit(&flags, geoidalBit, settings.flags.geoidalSeparation)
        upsertVarint(&fields, 7, UInt64(flags))
        upsertVarint(&fields, 13, gpsValue(settings.gpsMode))
        return serialize(fields)
    }

    static func displayConfig(merging existing: Data, settings: DisplaySettings) throws -> Data {
        var fields = try parse(existing)
        upsertVarint(&fields, 6, settings.units == .imperial ? 1 : 0)
        return serialize(fields)
    }

    static func configWrapper(kind: ConfigKind, body: Data) -> Data {
        let number: Int
        switch kind {
        case .device: number = 1
        case .position: number = 2
        case .display: number = 5
        case .lora: number = 6
        }
        return serialize([Field(number: number, value: .bytes(body))])
    }

    static func channelMessage(
        name: String,
        psk: Data,
        uplink: Bool,
        downlink: Bool,
        preciseLocation: Bool,
        channelID: UInt32
    ) throws -> Data {
        try mergedPrimaryChannel(
            existing: nil,
            name: name,
            psk: psk,
            uplink: uplink,
            downlink: downlink,
            preciseLocation: preciseLocation,
            channelID: channelID
        )
    }

    /// Patches the primary channel and keeps its id. A new id is used only when the radio has none.
    /// Callers compare the result with `canonical` so an identical channel is not written again.
    static func mergedPrimaryChannel(
        existing: Data?,
        name: String,
        psk: Data,
        uplink: Bool,
        downlink: Bool,
        preciseLocation: Bool,
        channelID: UInt32? = nil
    ) throws -> Data {
        let nameBytes = Data(name.utf8)
        guard nameBytes.count <= maxChannelNameBytes else { throw CodecError.channelNameTooLong }
        var channelFields: [Field] = []
        var settingFields: [Field] = []
        if let existing {
            channelFields = try parse(existing)
            if let settings = bytes(channelFields, 2) {
                settingFields = try parse(settings)
            }
        }
        let preservedID = channelID ?? fixed32(settingFields, 4) ?? UInt32.random(in: 1...UInt32.max)
        upsertBytes(&settingFields, 2, psk)
        upsertBytes(&settingFields, 3, nameBytes)
        upsertFixed32(&settingFields, 4, preservedID)
        upsertVarint(&settingFields, 5, uplink ? 1 : 0)
        upsertVarint(&settingFields, 6, downlink ? 1 : 0)
        var moduleFields: [Field] = []
        if let module = bytes(settingFields, 7) {
            moduleFields = try parse(module)
        }
        let precision = preciseLocation ? preciseLocationBits : coarseLocationBits
        upsertVarint(&moduleFields, 1, precision, force: true)
        upsertBytes(&settingFields, 7, serialize(moduleFields))
        upsertBytes(&channelFields, 2, serialize(settingFields))
        upsertVarint(&channelFields, 3, 1, force: true) // PRIMARY
        return serialize(channelFields)
    }

    static func canonical(_ data: Data) throws -> Data {
        serialize(try parse(data))
    }

    static func toRadioPacket(to node: UInt32, packetID: UInt32, admin: Data, wantResponse: Bool) -> Data {
        var dataFields: [Field] = []
        upsertVarint(&dataFields, 1, adminPort, force: true)
        upsertBytes(&dataFields, 2, admin)
        if wantResponse {
            upsertVarint(&dataFields, 3, 1, force: true)
        }
        var packet: [Field] = []
        packet.append(Field(number: 2, value: .fixed32(node)))
        packet.append(Field(number: 4, value: .bytes(serialize(dataFields))))
        packet.append(Field(number: 6, value: .fixed32(packetID)))
        packet.append(Field(number: 10, value: .varint(1)))
        packet.append(Field(number: 11, value: .varint(reliablePriority)))
        return serialize([Field(number: 1, value: .bytes(serialize(packet)))])
    }

    // MARK: - Decode

    static func classify(_ data: Data) throws -> Inbound {
        let fields = try parse(data)
        if let info = bytes(fields, 3), let node = varint(try parse(info), 1) {
            return .myNode(UInt32(truncatingIfNeeded: node))
        }
        if let configBytes = bytes(fields, 5) {
            if let slice = try configSlice(configBytes) {
                return .config(slice)
            }
            if let field = try configFieldNumber(configBytes) {
                return .otherConfig(field: field)
            }
        }
        if let moduleBytes = bytes(fields, 9) {
            let field = (try parse(moduleBytes).first?.number) ?? 0
            return .moduleConfig(field: field)
        }
        if let channelBytes = bytes(fields, 10) {
            return .channel(try parsedChannel(channelBytes))
        }
        if let complete = varint(fields, 7) {
            return .configComplete(UInt32(truncatingIfNeeded: complete))
        }
        if let noticeBytes = bytes(fields, 16) {
            let noticeFields = try parse(noticeBytes)
            if let message = bytes(noticeFields, 4), let text = String(data: message, encoding: .utf8), !text.isEmpty {
                return .notice(String(text.prefix(180)))
            }
        }
        if let packetBytes = bytes(fields, 2) {
            return try classifyPacket(packetBytes)
        }
        return .other
    }

    static func snapshot(inventory: RadioInventory) throws -> DeviceSnapshot {
        guard let raw = try primaryChannel(in: inventory.channels) else { throw CodecError.malformed }
        return try snapshot(
            lora: inventory.lora,
            device: inventory.device,
            position: inventory.position,
            channel: try parsedChannel(raw),
            owner: inventory.owner
        )
    }

    static func snapshot(
        lora: Data,
        device: Data,
        position: Data,
        channel: ParsedChannel,
        owner: Data
    ) throws -> DeviceSnapshot {
        let loraFields = try parse(lora)
        let deviceFields = try parse(device)
        let positionFields = try parse(position)
        let preset = modemPreset(varint(loraFields, 2) ?? 0)
        let slot = UInt32(truncatingIfNeeded: varint(loraFields, 11) ?? 0)
        let role = deviceRole(varint(deviceFields, 1) ?? 0)
        let rebroadcast = rebroadcastMode(varint(deviceFields, 6) ?? 0)
        let flagsValue = UInt32(truncatingIfNeeded: varint(positionFields, 7) ?? 0)
        let flags = PositionFlagSet(
            altitude: flagsValue & altitudeBit != 0,
            altitudeMSL: flagsValue & altitudeMSLBit != 0,
            geoidalSeparation: flagsValue & geoidalBit != 0
        )
        let isPrimary = channel.role == 1
        return DeviceSnapshot(
            modemPreset: preset,
            ignoreMQTT: (varint(loraFields, 104) ?? 0) != 0,
            frequencySlot: slot,
            primaryChannelName: isPrimary ? channel.name : nil,
            primaryHasNonDefaultPSK: isPrimary ? channel.nonDefaultPSK : false,
            preciseLocation: isPrimary ? channel.preciseLocation : false,
            role: role,
            rebroadcastMode: rebroadcast,
            smartPosition: (varint(positionFields, 2) ?? 0) != 0,
            positionFlags: flags,
            longName: try longName(from: owner)
        )
    }

    static func isNonDefaultAES256(_ psk: Data) -> Bool {
        guard psk.count == 32 else { return false }
        if psk.allSatisfy({ $0 == 0 }) { return false }
        let prefixMatches = psk.prefix(documentedDefaultPSK.count).elementsEqual(documentedDefaultPSK)
        let suffixClear = psk.dropFirst(documentedDefaultPSK.count).allSatisfy({ $0 == 0 })
        if prefixMatches && suffixClear { return false }
        return true
    }

    static func routingFailureText(_ code: UInt64) -> String {
        switch code {
        case 36:
            return "The radio rejected the admin session. Disconnect and try this radio again."
        case 33:
            return "The radio refused the admin write as not authorized."
        case 32:
            return "The radio rejected the admin write as a bad request."
        default:
            return "The radio rejected the admin write (routing \(code))."
        }
    }

    // MARK: - Self-check (official protoc vectors, no fleet keys)

    static func selfCheck() -> Bool {
        do {
            return try runSelfCheck()
        } catch {
            return false
        }
    }

    private static func runSelfCheck() throws -> Bool {
        guard try encodeMatches("18ac9e04", wantConfig(nonce: 69420)) else { return false }
        guard try encodeMatches("1801", getOwnerAdmin()) else { return false }
        guard try encodeMatches("2800", getConfigAdmin(kind: 0, passkey: nil)) else { return false }
        guard try encodeMatches(
            "2805aa06080102030405060708",
            getConfigAdmin(kind: 5, passkey: Data([UInt8(1), 2, 3, 4, 5, 6, 7, 8]))
        ) else { return false }

        let loraBase = try data(hex: "080118fa012007280838014003480150165814")
        let lora = LoRaSettings(
            usePreset: true,
            modemPreset: .shortTurbo,
            ignoreMQTT: true,
            frequencySlot: 50,
            region: .us
        )
        guard try encodeMatches(
            "0801100818fa012007280838014003480150165832c00601",
            loraConfig(merging: loraBase, settings: lora)
        ) else { return false }
        let loraBody = try loraConfig(merging: loraBase, settings: lora)
        let wrapped = setConfigAdmin(config: configWrapper(kind: .lora, body: loraBody), passkey: Data([UInt8(1), 2, 3, 4, 5, 6, 7, 8]))
        guard try encodeMatches(
            "92021a32180801100818fa012007280838014003480150165832c00601aa06080102030405060708",
            wrapped
        ) else { return false }

        let deviceBase = try data(hex: "080a300238b0545a03455354")
        let device = DeviceSettings(rebroadcastMode: .localOnly, timezone: "EST")
        guard try encodeMatches(
            "0807300238b0545a03455354",
            deviceConfig(merging: deviceBase, role: .tak, settings: device)
        ) else { return false }

        let positionBase = try data(hex: "0884073802")
        let position = PositionSettings(
            smartPosition: true,
            flags: PositionFlagSet(altitude: true, altitudeMSL: false, geoidalSeparation: true),
            gpsMode: .enabled
        )
        guard try encodeMatches(
            "088407100138056801",
            positionConfig(merging: positionBase, settings: position)
        ) else { return false }

        let displayBase = try data(hex: "083c")
        guard try encodeMatches(
            "083c3001",
            displayConfig(merging: displayBase, settings: DisplaySettings(units: .imperial))
        ) else { return false }

        // 0x5A repeated is an encoder fixture, not a fleet key.
        let channel = try channelMessage(
            name: "TAK",
            psk: Data(repeating: 0x5A, count: 32),
            uplink: true,
            downlink: true,
            preciseLocation: true,
            channelID: 0x11223344
        )
        guard try encodeMatches(
            "123412205a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a1a0354414b2544332211280130013a0208201801",
            channel
        ) else { return false }

        guard try encodeMatches(
            "880602aa06080102030405060708",
            rebootAdmin(seconds: 2, passkey: Data([UInt8(1), 2, 3, 4, 5, 6, 7, 8]))
        ) else { return false }
        let passkey = Data([UInt8(1), 2, 3, 4, 5, 6, 7, 8])
        guard try encodeMatches("800401aa06080102030405060708", beginEditAdmin(passkey: passkey)) else { return false }
        guard try encodeMatches("880401aa06080102030405060708", commitEditAdmin(passkey: passkey)) else { return false }

        let existingOwner = try data(hex: "0a032161623001420111")
        let renamed = try userMessage(merging: existingOwner, longName: "Koala", shortName: "Koal")
        guard try encodeMatches("0a0321616212054b6f616c611a044b6f616c3001420111", renamed) else { return false }
        guard try longName(from: renamed) == "Koala" else { return false }
        guard try shortName(from: renamed) == "Koal" else { return false }
        let longOnly = try userMessage(merging: existingOwner, longName: "Koala", shortName: nil)
        guard try encodeMatches("0a0321616212054b6f616c613001420111", longOnly) else { return false }
        guard try shortName(from: longOnly) == nil else { return false }
        guard try encodeMatches(
            "8202170a0321616212054b6f616c611a044b6f616c3001420111",
            setOwnerAdmin(user: renamed, passkey: Data())
        ) else { return false }

        let wrappedPacket = toRadioPacket(
            to: 0xA1B2C3D4,
            packetID: 0x01020304,
            admin: getOwnerAdmin(),
            wantResponse: true
        )
        guard try encodeMatches(
            "0a1815d4c3b2a122080806120218011801350403020150015846",
            wrappedPacket
        ) else { return false }

        guard case .configComplete(69420) = try classify(data(hex: "080738ac9e04")) else { return false }
        guard case .myNode(0xA1B2C3D4) = try classify(data(hex: "1a0608d487cb8d0a")) else { return false }
        guard case .routing(let ackID, let ackError) = try classify(data(hex: "1209220708053504030201")),
              ackID == 0x01020304, ackError == nil else { return false }
        guard case .routing(let badID, let badError) = try classify(data(hex: "120d220b0805120218243504030201")),
              badID == 0x01020304, badError == 36 else { return false }
        guard case .otherConfig(3) = try classify(data(hex: "2a021a00")) else { return false }
        guard case .moduleConfig(1) = try classify(data(hex: "4a020a00")) else { return false }
        guard case .config(let slice) = try classify(data(hex: "2a0b3209080118fa0140034801")),
              slice.kind == .lora else { return false }
        let preserved = try loraConfig(merging: slice.body, settings: lora)
        guard (try parse(preserved)).contains(where: { $0.number == 9 }) else { return false }
        return true
    }

    // MARK: - Wire

    static func parse(_ data: Data) throws -> [Field] {
        var fields: [Field] = []
        var index = 0
        while index < data.count {
            let key = try readVarint(data, &index)
            let number = Int(key >> 3)
            let wire = Int(key & 7)
            guard number > 0 else { throw CodecError.malformed }
            switch wire {
            case 0:
                let value = try readVarint(data, &index)
                fields.append(Field(number: number, value: .varint(value)))
            case 1:
                guard index + 8 <= data.count else { throw CodecError.malformed }
                fields.append(Field(number: number, value: .fixed64(Data(data[index..<(index + 8)]))))
                index += 8
            case 2:
                let length = try readVarint(data, &index)
                guard length <= UInt64(data.count - index) else { throw CodecError.malformed }
                let end = index + Int(length)
                fields.append(Field(number: number, value: .bytes(Data(data[index..<end]))))
                index = end
            case 5:
                guard index + 4 <= data.count else { throw CodecError.malformed }
                let value = UInt32(data[index])
                    | (UInt32(data[index + 1]) << 8)
                    | (UInt32(data[index + 2]) << 16)
                    | (UInt32(data[index + 3]) << 24)
                fields.append(Field(number: number, value: .fixed32(value)))
                index += 4
            default:
                throw CodecError.malformed
            }
        }
        return fields
    }

    static func serialize(_ fields: [Field]) -> Data {
        var out = Data()
        for field in fields.sorted(by: { $0.number < $1.number }) {
            switch field.value {
            case .varint(let value):
                out.append(encodeVarint(UInt64((field.number << 3) | 0)))
                out.append(encodeVarint(value))
            case .fixed64(let value):
                out.append(encodeVarint(UInt64((field.number << 3) | 1)))
                out.append(value.prefix(8))
            case .bytes(let value):
                out.append(encodeVarint(UInt64((field.number << 3) | 2)))
                out.append(encodeVarint(UInt64(value.count)))
                out.append(value)
            case .fixed32(let value):
                out.append(encodeVarint(UInt64((field.number << 3) | 5)))
                out.append(UInt8(value & 0xff))
                out.append(UInt8((value >> 8) & 0xff))
                out.append(UInt8((value >> 16) & 0xff))
                out.append(UInt8((value >> 24) & 0xff))
            }
        }
        return out
    }

    static func upsertVarint(_ fields: inout [Field], _ number: Int, _ value: UInt64, force: Bool = false) {
        fields.removeAll { $0.number == number }
        if value != 0 || force {
            fields.append(Field(number: number, value: .varint(value)))
        }
    }

    static func upsertFixed32(_ fields: inout [Field], _ number: Int, _ value: UInt32) {
        fields.removeAll { $0.number == number }
        if value != 0 {
            fields.append(Field(number: number, value: .fixed32(value)))
        }
    }

    static func upsertBytes(_ fields: inout [Field], _ number: Int, _ data: Data) {
        fields.removeAll { $0.number == number }
        if !data.isEmpty {
            fields.append(Field(number: number, value: .bytes(data)))
        }
    }

    static func varint(_ fields: [Field], _ number: Int) -> UInt64? {
        for field in fields where field.number == number {
            if case .varint(let value) = field.value { return value }
        }
        return nil
    }

    static func bytes(_ fields: [Field], _ number: Int) -> Data? {
        for field in fields where field.number == number {
            if case .bytes(let value) = field.value { return value }
        }
        return nil
    }

    // MARK: - Private mapping

    private static func classifyPacket(_ data: Data) throws -> Inbound {
        let packet = try parse(data)
        guard let decoded = bytes(packet, 4) else { return .other }
        let dataFields = try parse(decoded)
        guard let port = varint(dataFields, 1) else { return .other }
        let requestID = fixed32(dataFields, 6)
        let replyID = fixed32(dataFields, 7)
        let matched = requestID ?? replyID
        guard let matched else { return .other }
        if port == routingPort {
            let routingFields: [Field]
            if let payload = bytes(dataFields, 2) {
                routingFields = try parse(payload)
            } else {
                routingFields = []
            }
            return .routing(requestID: matched, error: varint(routingFields, 3))
        }
        if port == adminPort {
            let payload = bytes(dataFields, 2) ?? Data()
            return .admin(requestID: matched, message: try parsedAdmin(payload))
        }
        return .other
    }

    private static func parsedAdmin(_ data: Data) throws -> ParsedAdmin {
        let fields = try parse(data)
        var message = ParsedAdmin(passkey: bytes(fields, passkeyField), config: nil, channel: nil, owner: nil)
        if let configBytes = bytes(fields, 6) {
            message.config = try configSlice(configBytes)
        }
        if let channelBytes = bytes(fields, 2) {
            message.channel = try parsedChannel(channelBytes)
        }
        if let ownerBytes = bytes(fields, 4), !ownerBytes.isEmpty {
            message.owner = ownerBytes
        }
        return message
    }

    private static func text(from user: Data, field: Int) throws -> String? {
        guard let raw = bytes(try parse(user), field), !raw.isEmpty else { return nil }
        return String(data: raw, encoding: .utf8)
    }

    private static func editTransactionAdmin(field: Int, passkey: Data) -> Data {
        var fields: [Field] = []
        upsertVarint(&fields, field, 1, force: true)
        if passkey.count == 8 {
            upsertBytes(&fields, passkeyField, passkey)
        }
        return serialize(fields)
    }

    private static func configFieldNumber(_ data: Data) throws -> Int? {
        for field in try parse(data) {
            switch field.number {
            case 1, 2, 3, 4, 5, 6, 7, 8:
                return field.number
            default:
                continue
            }
        }
        return nil
    }

    private static func configSlice(_ data: Data) throws -> ConfigSlice? {
        let fields = try parse(data)
        if let body = bytes(fields, 1) { return ConfigSlice(kind: .device, body: body) }
        if let body = bytes(fields, 2) { return ConfigSlice(kind: .position, body: body) }
        if let body = bytes(fields, 5) { return ConfigSlice(kind: .display, body: body) }
        if let body = bytes(fields, 6) { return ConfigSlice(kind: .lora, body: body) }
        return nil
    }

    private static func parsedChannel(_ data: Data) throws -> ParsedChannel {
        let fields = try parse(data)
        let index = Int(varint(fields, 1) ?? 0)
        let role = Int(varint(fields, 3) ?? 0)
        var name: String?
        var nonDefault = false
        var precise = false
        if let settings = bytes(fields, 2) {
            let settingFields = try parse(settings)
            if let rawName = bytes(settingFields, 3) {
                name = String(data: rawName, encoding: .utf8)
            }
            if let psk = bytes(settingFields, 2) {
                nonDefault = isNonDefaultAES256(psk)
            }
            if let module = bytes(settingFields, 7) {
                let moduleFields = try parse(module)
                precise = (varint(moduleFields, 1) ?? 0) >= preciseLocationBits
            }
        }
        return ParsedChannel(
            index: index,
            role: role,
            name: name,
            nonDefaultPSK: nonDefault,
            preciseLocation: precise,
            raw: data
        )
    }

    private static func fixed32(_ fields: [Field], _ number: Int) -> UInt32? {
        for field in fields where field.number == number {
            if case .fixed32(let value) = field.value { return value }
        }
        return nil
    }

    private static func modemPresetValue(_ preset: ModemPreset) -> UInt64 {
        switch preset {
        case .longFast: return 0
        case .mediumFast: return 4
        case .shortTurbo: return 8
        }
    }

    private static func modemPreset(_ value: UInt64) -> ModemPreset? {
        switch value {
        case 0: return .longFast
        case 4: return .mediumFast
        case 8: return .shortTurbo
        default: return nil
        }
    }

    private static func regionValue(_ region: LoRaRegion) -> UInt64 {
        switch region {
        case .unset: return 0
        case .us: return 1
        case .eu868: return 3
        }
    }

    private static func roleValue(_ role: DeviceRole) -> UInt64 {
        switch role {
        case .tak: return 7
        case .takTracker: return 10
        case .clientBase: return 12
        }
    }

    private static func deviceRole(_ value: UInt64) -> DeviceRole? {
        switch value {
        case 7: return .tak
        case 10: return .takTracker
        case 12: return .clientBase
        default: return nil
        }
    }

    private static func rebroadcastValue(_ mode: RebroadcastMode) -> UInt64 {
        switch mode {
        case .all: return 0
        case .localOnly: return 2
        case .none: return 4
        }
    }

    private static func rebroadcastMode(_ value: UInt64) -> RebroadcastMode? {
        switch value {
        case 0: return .all
        case 2: return .localOnly
        case 4: return RebroadcastMode.none
        default: return nil
        }
    }

    private static func gpsValue(_ mode: GPSMode) -> UInt64 {
        switch mode {
        case .disabled: return 0
        case .enabled: return 1
        case .notPresent: return 2
        }
    }

    private static func setBit(_ flags: inout UInt32, _ bit: UInt32, _ on: Bool) {
        if on {
            flags |= bit
        } else {
            flags &= ~bit
        }
    }

    private static func readVarint(_ data: Data, _ index: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.count && shift <= 63 {
            let byte = UInt64(data[index])
            index += 1
            result |= (byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        throw CodecError.malformed
    }

    private static func encodeVarint(_ value: UInt64) -> Data {
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
                break
            }
        }
        return out
    }

    private static func data(hex: String) throws -> Data {
        guard hex.count.isMultiple(of: 2) else { throw CodecError.malformed }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { throw CodecError.malformed }
            out.append(byte)
            index = next
        }
        return out
    }

    private static func encodeMatches(_ hex: String, _ data: Data) throws -> Bool {
        data == (try self.data(hex: hex))
    }
}
