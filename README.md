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

The Mesh Config target is **1.1.1 (3)**: `MARKETING_VERSION` is the short version, `CURRENT_PROJECT_VERSION` is the build number. Settings shows `Version 1.1.1 (3)` from the app bundle, and the Apply screen repeats that line. After you pull and Run, those screens should show this number.

Bump both values on every shippable change so a TestFlight or device install can be told apart from the last one. Raise `CURRENT_PROJECT_VERSION` by 1 each time, in both the Debug and Release configurations. Raise `MARKETING_VERSION` when you want a new short version (1.1.1, then 1.2.0). Do not type the number into Swift; Settings and Apply read `CFBundleShortVersionString` and `CFBundleVersion`.

Bluetooth permission is requested when you scan. The usage string is `NSBluetoothAlwaysUsageDescription` in `MeshConfig/Info.plist`.

A Linux checkout cannot run `xcodebuild`. The project file is still a normal Xcode project (`project.pbxproj`, shared scheme, Swift sources).

### Try the loop without a radio

Debug builds have **Simulated radios (DEBUG)** on the Apply tab. That transport is compiled only with `#if DEBUG`. It is labeled DEBUG on every row. It walks handshake, the section order, reboot reconnects, channel send, and verify in the UI. It does not talk to hardware. The live radio path is the CoreBluetooth transport, which encodes real PhoneAPI admin messages.

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

Order, because the name, LoRa, Device, Position, and Display reboot on save and Channel does not:

1. Connect and PhoneAPI handshake (`wantConfig`, drain FromRadio, seed `session_passkey`).
2. Ensure the fleet key is in the Keychain.
3. Name — `set_owner` for this radio only. The **long name** is the callsign ATAK shows. The **short name** is the 4-character mesh badge (blank uses the first 4 characters of the long name). Then reboot and reconnect.
4. LoRa — preset ShortTurbo, Ignore MQTT, frequency slot from the profile (50 on the TAK template), region from the profile. Then reboot and reconnect.
5. Device — role chosen for this radio, rebroadcast LOCAL_ONLY, optional POSIX time zone. Then reboot and reconnect.
6. Position — smart position from the profile, `ALTITUDE` and `GEOIDAL_SEPARATION`, **not** `ALTITUDE_MSL`. Then reboot and reconnect.
7. Display — imperial or metric from the profile. Then reboot and reconnect.
8. Channel — remove the default LongFast/ShortFast primary, write the private primary (name, 32-byte key, precise location, uplink and downlink), and **Send**. No reboot.
9. Read back and require every TAK check in `ProfileAcceptance.evaluate`, including that the long name matches what was entered.
10. Disconnect. Show pass or fail. Failed checks are ids and labels only. A successful verify stores that long name and short name on the device roster.

After each reboot section the app waits up to 60 seconds for the link to drop, then up to 90 seconds for Bluetooth to come back and the handshake to finish. A tracker can beep late in that window. One missed connect does not end the wait.

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

Handshake writes `ToRadio.want_config_id` **69420** (firmware’s config-only nonce, so the node database is not downloaded), drains FromRadio until `config_complete_id` matches, then sends `AdminMessage.get_owner_request` to seed the 8-byte `session_passkey`. Mutating admin messages include that passkey. It stays in memory for the connection and is never logged. The owner record from that reply is kept only so the later `set_owner` can change the long and short names without clearing the node id, public key, or license flag.

The first mutating write is `set_owner` (`AdminMessage` field 32, `User.long_name` / `User.short_name`). Current firmware saves that and reboots. The long name is limited to 24 UTF-8 bytes. The short name is limited to 4 UTF-8 bytes. LoRa, device, position, and display are each `set_config`. Channel is last: one `set_channel` of the primary (index 0, 32-byte key, precise location = 32 position bits) which saves without a reboot. Mutating admin messages set `want_response`. Firmware answers with a `Routing` packet (`error_reason` NONE, `request_id` equal to the packet id) after AdminModule accepts the write. A Bluetooth `want_ack` alone is not treated as success, because that ack can be generated before the admin module runs.

Current firmware applies LoRa changes live and does not reboot for a units-only display write. Role, rebroadcast, and position changes still drop Bluetooth. If a config section stays connected after the routing ack, the transport sends `reboot_seconds` so the apply loop can reconnect and continue. Channel does not.

Read-back uses `get_owner`, `get_config`, and `get_channel` for the checklist fields in `ProfileAcceptance`. The long-name row must match the name entered for this radio.

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
