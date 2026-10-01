import Foundation

/// Safe-to-show description of a sync. Payloads that contain key material stay in `SyncPlan.writes`.
struct SyncProgress: Equatable, Sendable {
    var summary: String
    var titles: [String]
    var isEmpty: Bool
}

struct SyncChange: Equatable, Sendable, Identifiable {
    var id: String
    var title: String
}

enum SyncWrite: Equatable, Sendable {
    /// Merged `User` bytes. May contain the node public key. Do not log.
    case owner(Data)
    /// Merged config subsection body.
    case config(PhoneAPICodec.ConfigKind, Data)
    /// Merged primary `Channel` message. Contains the PSK. Do not log.
    case channel(Data)
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
        SyncProgress(summary: summary, titles: changes.map(\.title), isEmpty: isEmpty)
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
    /// ModuleConfig oneof field numbers seen during the drain. Bodies are not kept.
    var observedModuleFields: Set<Int>

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
                }
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
}

extension SyncError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPSK:
            return "The fleet PSK must be 32 bytes before a channel write."
        case .channelName:
            return "The channel name must be shorter than 12 bytes."
        }
    }
}

/// Compares a radio inventory to the profile and returns only the admin writes that differ.
enum SyncDiff {
    static func plan(
        inventory: RadioInventory,
        profile: FleetProfile,
        role: DeviceRole,
        names: RadioNames,
        longEdited: Bool,
        shortEdited: Bool,
        psk: Data
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
            if longTarget != nil {
                changes.append(SyncChange(id: "owner.long", title: "Long name"))
            }
            if shortTarget != nil {
                changes.append(SyncChange(id: "owner.short", title: "Short name"))
            }
            let user = try PhoneAPICodec.userMessage(
                merging: inventory.owner,
                longName: longTarget,
                shortName: shortTarget
            )
            writes.append(.owner(user))
        }

        let lora = try PhoneAPICodec.loraConfig(merging: inventory.lora, settings: profile.lora)
        if try lora != PhoneAPICodec.canonical(inventory.lora) {
            changes.append(SyncChange(id: "lora", title: "LoRa"))
            writes.append(.config(.lora, lora))
        }

        let device = try PhoneAPICodec.deviceConfig(
            merging: inventory.device,
            role: role,
            settings: profile.device
        )
        if try device != PhoneAPICodec.canonical(inventory.device) {
            changes.append(SyncChange(id: "device", title: "Device"))
            writes.append(.config(.device, device))
        }

        let position = try PhoneAPICodec.positionConfig(merging: inventory.position, settings: profile.position)
        if try position != PhoneAPICodec.canonical(inventory.position) {
            changes.append(SyncChange(id: "position", title: "Position"))
            writes.append(.config(.position, position))
        }

        let display = try PhoneAPICodec.displayConfig(merging: inventory.display, settings: profile.display)
        if try display != PhoneAPICodec.canonical(inventory.display) {
            changes.append(SyncChange(id: "display", title: "Display"))
            writes.append(.config(.display, display))
        }

        let existingChannel = try PhoneAPICodec.primaryChannel(in: inventory.channels)
        let channel: Data
        do {
            channel = try PhoneAPICodec.mergedPrimaryChannel(
                existing: existingChannel,
                name: profile.channel.name,
                psk: psk,
                uplink: profile.channel.uplinkEnabled,
                downlink: profile.channel.downlinkEnabled,
                preciseLocation: profile.channel.preciseLocation
            )
        } catch PhoneAPICodec.CodecError.channelNameTooLong {
            throw SyncError.channelName
        }
        let channelChanged: Bool
        if let existingChannel {
            channelChanged = try channel != PhoneAPICodec.canonical(existingChannel)
        } else {
            channelChanged = true
        }
        if channelChanged {
            changes.append(SyncChange(id: "channel", title: "Channel"))
            writes.append(.channel(channel))
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
