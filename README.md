# Mesh Config

iPhone app for configuring a Meshtastic fleet one radio at a time over Bluetooth. You save a fleet profile on the phone, pick a role for the radio in front of you, apply the whole profile, verify the read-back, disconnect, then move to the next radio.

The primary profile is the TAK tracker / ATAK-over-Meshtastic setup: ShortTurbo, Ignore MQTT on, frequency slot 50, a private primary channel, rebroadcast LOCAL_ONLY, and position flags that give TAK height above ellipsoid (HAE) rather than mean sea level.

This repository is the Mesh Config app. It is not the Meshtastic firmware tree.

## Open in Xcode

Requirements: Xcode 15 or later, iOS 17 or later, an iPhone or the iPhone simulator. The project is iPhone-only (not macOS, not Mac Catalyst).

1. Open `MeshConfig.xcodeproj`.
2. Select the **Mesh Config** scheme.
3. Choose an iPhone simulator or a paired iPhone.
4. Set your signing team on the Mesh Config target if you run on a device. The bundle id is `com.meshconfig.app`.
5. Run.

The Mesh Config target is **1.2.0 (4)**: `MARKETING_VERSION` is the short version, `CURRENT_PROJECT_VERSION` is the build number. Settings shows `Version 1.2.0 (4)` from the app bundle, and the Apply screen repeats that line. After you pull and Run, those screens should show this number.

Bump both values on every shippable change so a TestFlight or device install can be told apart from the last one. Raise `CURRENT_PROJECT_VERSION` by 1 each time, in both the Debug and Release configurations. Raise `MARKETING_VERSION` when you want a new short version (1.1.1, then 1.2.0). Do not type the number into Swift; Settings and Apply read `CFBundleShortVersionString` and `CFBundleVersion`.

Bluetooth permission is requested when you scan. The usage string is `NSBluetoothAlwaysUsageDescription` in `MeshConfig/Info.plist`.

A Linux checkout cannot run `xcodebuild`. The project file is still a normal Xcode project (`project.pbxproj`, shared scheme, Swift sources).

### Try the loop without a radio

Debug builds have **Simulated radios (DEBUG)** on the Apply tab. That transport is compiled only with `#if DEBUG`. It is labeled DEBUG on every row. It walks handshake, a diff against the profile, one reboot when something differs, and verify in the UI. A second sync of the same simulated radio with no name edits reports already up to date and does not reboot. It does not talk to hardware. The live radio path is the CoreBluetooth transport, which encodes real PhoneAPI admin messages.

Release builds only include the CoreBluetooth transport.

## What the tabs do

| Tab | Role |
| --- | --- |
| Profiles | Saved fleet profiles. New profiles start from the TAK Tracker defaults. |
| Devices | Radios this phone has applied, or last attempted. |
| Apply | Pick a profile, pick a role, scan, apply, verify, then next radio or done. |
| Settings | Installed version, default region and display units for new profiles, last profile, and the limits below. |

Role is asked for every radio:

- **TAK Tracker** — standalone tracker, no ATAK end-user device on this phone.
- **TAK** — this radio is paired to a phone that will run ATAK or iTAK plus the Meshtastic app’s Local TAK Server.

After a pass, **Next device** keeps the profile and clears the role so the next radio is an explicit choice. The app never auto-connects the next radio.

Changing a role on the Devices tab does not write Bluetooth. It marks **Needs re-apply** until Apply succeeds. Removing a row only edits the list on this phone. The radio is not factory reset.

## PSK and Keychain

One generated AES-256 (32-byte) key per fleet profile.

- Keychain service: `com.meshconfig.fleet.psk`
- Account: `fleet-psk.<profileUUID>`
- Accessibility: `AfterFirstUnlockThisDeviceOnly`
- The profile file stores `PSKReference.keychainAccount` only. It never stores key bytes.
- There is no paste or import in this version.
- Rotate overwrites that Keychain item. Radios keep the previous mesh until you re-apply them.
- The key is not shown, logged, or written into screenshots by the app.
- Duplicate profile creates a new profile id and a new key. It does not share the original Keychain item.
- Delete profile deletes that Keychain item.

`FleetPSKStore.ensurePSK` runs before a channel write. If the key is missing, apply fails and does not send a partial channel.

Details: [docs/PSK_POLICY.md](docs/PSK_POLICY.md).

## Apply and verify

One active Bluetooth link. The next session waits until the current one is idle or disconnected.

Sync compares the radio to the profile and writes only what differs. Identical values are not sent, because rewriting them is what rebooted the radio over and over.

1. Connect and PhoneAPI handshake (`want_config_id` 69420). Drain FromRadio until config complete: every config section, module config, and channel. Then `get_owner` for the owner record and the 8-byte `session_passkey`.
2. Ensure the fleet key is in the Keychain.
3. Compare. The long name is the callsign ATAK shows. The short name is the 4-byte mesh badge. Both are optional. If both fields are blank, the owner record is not sent. A non-blank field is sent only when it differs from the radio. If the fields were filled from the roster and not edited, the names read from the radio win and nothing is written for the owner. LoRa, device, position, display, and the primary channel are included only when the merged payload differs.
4. If nothing differs, write nothing and do not reboot. The progress line says **Already up to date**.
5. If something differs, one edit transaction: `begin_edit_settings`, the differing `set_owner` / `set_config` / `set_channel` messages, then `commit_edit_settings`. The radio reboots at most once. The progress line says how many settings will change.
6. After that reboot, wait up to 60 seconds for the link to drop, then up to 90 seconds for Bluetooth to come back and the handshake to finish. A tracker can beep late in that window. One missed connect does not end the wait. The handshake does not write again.
7. Read back and require every TAK check in `ProfileAcceptance.evaluate`. The long-name row must match only when this sync changed the long name. Otherwise the radio’s existing long name is accepted.
8. Disconnect. Show pass or fail. Failed checks are ids and labels only. A successful verify stores the long name and short name that are on the radio after the sync.

Power, network, Bluetooth, security, and module config are read during the handshake and are not written. Security and module bodies are not kept, and key bytes are not logged.

Full checklist and timeouts: [docs/APPLY_VERIFY.md](docs/APPLY_VERIFY.md). Screen contract: [docs/SCREENS_UX.md](docs/SCREENS_UX.md).

Profiles and the device roster are JSON files under Application Support (`fleet-profiles.json`, `configured-devices.json`). Saving a profile strips any exportable key field and locks the TAK template invariants (ShortTurbo, LOCAL_ONLY, HAE altitude, precise location, replace default primary).

## Radios

Bluetooth setup is the same path for:

- **Heltec WiFi LoRa 32 V3** — this board has Wi‑Fi hardware. Mesh Config does not use it. Meshtastic Wi‑Fi is not a native home TAK server.
- **Heltec Mesh Node T114** — no Wi‑Fi. Do not treat it as a Wi‑Fi node.
- **SenseCAP T1000-E** — tracker with GPS. Same Bluetooth config path.

ATAK or iTAK on the phone talks to the Local TAK Server inside the Meshtastic phone app, on that same phone. Packaging that server, flashing firmware, and programming a dock of radios over USB are out of scope here. V3 firmware is flashed from a computer. T114 and T1000-E updates are separate OTA paths.

## PhoneAPI protobufs

Live apply encodes and decodes the Meshtastic PhoneAPI admin subset in `MeshConfig/Apply/PhoneAPICodec.swift`: `ToRadio`, `FromRadio`, `MeshPacket`, `Data`, `AdminMessage`, `Config`, and `Channel`.

The field numbers match [meshtastic/protobufs](https://github.com/meshtastic/protobufs) commit `ad0bf31e82886d794334dcc62abb80da862a8ec7` (master, 2026-09-25). This repo does not vendor the protobuf tree or generated SwiftProtobuf sources. The codec keeps unknown fields inside a config body so a `set_config` does not wipe settings the profile does not own (for example LoRa transmit enable).

Handshake writes `ToRadio.want_config_id` **69420** (firmware’s config-only nonce, so the node database is not downloaded), drains FromRadio until `config_complete_id` matches, then sends `AdminMessage.get_owner_request` to seed the 8-byte `session_passkey`. The drain is the full current config: config sections (device, position, power, network, display, LoRa, Bluetooth, security), module config, and channels. Power, network, Bluetooth, security, and module-config bodies are not retained and are not written back. Mutating admin messages include the passkey. It stays in memory for the connection and is never logged. The owner record is kept only so a later `set_owner` can change a name without clearing the node id, public key, or license flag.

Writes go out only inside `begin_edit_settings` (AdminMessage field 64) and `commit_edit_settings` (field 65). `set_owner` is field 32 and is sent only for a non-blank name that differs from the radio. The long name is limited to 24 UTF-8 bytes. The short name is limited to 4 UTF-8 bytes. A blank field is omitted, not cleared. LoRa, device, position, and display are `set_config` of a merged subsection, and only when the merged bytes differ. The primary channel is one `set_channel` that keeps the radio’s channel id and replaces the name, 32-byte key, and precise-location bits (32) when those differ. Mutating admin messages set `want_response`. Firmware answers with a `Routing` packet (`error_reason` NONE, `request_id` equal to the packet id) after AdminModule accepts the write. A Bluetooth `want_ack` alone is not treated as success, because that ack can be generated before the admin module runs. A link drop before `commit_edit_settings` fails the sync. The commit itself reboots the radio once (`disableBluetooth`, then `saveChanges`). If the link is still up after the commit ack, the transport sends `reboot_seconds` so the session still reconnects once. An empty diff does not begin or commit, and it does not reboot.

Read-back uses `get_owner`, `get_config`, and `get_channel` after that single reconnect, or immediately when nothing was written. The long-name row must match the callsign only when this sync changed it.

To regenerate after a protobuf change: check out that commit or a newer `meshtastic/protobufs` master, diff `meshtastic/mesh.proto`, `admin.proto`, `config.proto`, `channel.proto`, and `portnums.proto` against the constants in `PhoneAPICodec.swift`, and update the codec. `PhoneAPICodec.selfCheck()` compares a few frames to bytes produced by `protoc` for this commit; a handshake refuses to write if that check fails.

## Known limits

CoreBluetooth scan, connect, and GATT discovery use the public Meshtastic service (`6BA1B218-15A8-461F-9FA8-5DCAE273EAFD`) and the ToRadio, FromRadio, and FromNum characteristics.

Managed-mode radios ignore local Bluetooth admin. This app does not flash firmware, does not program Wi‑Fi, and does not configure a Local TAK Server. A Linux checkout still cannot run `xcodebuild`.

## Project layout

```
MeshConfig.xcodeproj
MeshConfig/
  MeshConfigApp.swift
  Info.plist
  Models/            FleetProfile, ConfiguredDevice
  Security/          FleetPSKStore (Keychain)
  Apply/             ApplySession, PhoneAPI codec, CoreBluetooth transport, DEBUG simulator
  Persistence/       profile and roster files
  UI/                Profiles, Devices, Apply, Settings
docs/                PSK, apply/verify, and screen specs
```
