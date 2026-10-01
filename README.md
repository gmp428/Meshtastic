# Mesh Config

iPhone app for configuring a Meshtastic fleet one radio at a time over Bluetooth. You save a fleet profile on the phone, pick a role for the radio in front of you, apply the whole profile, verify the read-back, disconnect, then move to the next radio.

The primary profile is the TAK tracker / ATAK-over-Meshtastic setup: ShortTurbo, Ignore MQTT off, Ok to MQTT on, hop limit 3, transmit on, frequency slot 50, a private primary channel with uplink and downlink, rebroadcast ALL, and position flags that give TAK height above ellipsoid (HAE) rather than mean sea level. Each radio is a Tracker or a Gateway. Trackers keep the MQTT module off. The gateway is a CLIENT that joins Wi-Fi and publishes the fleet to OpenTAKServer.

This repository is the Mesh Config app. It is not the Meshtastic firmware tree.

## Open in Xcode

Requirements: Xcode 15 or later, iOS 17 or later, an iPhone or the iPhone simulator. The project is iPhone-only (not macOS, not Mac Catalyst).

1. Open `MeshConfig.xcodeproj`.
2. Select the **Mesh Config** scheme.
3. Choose an iPhone simulator or a paired iPhone.
4. Set your signing team on the Mesh Config target if you run on a device. The bundle id is `com.meshconfig.app`.
5. Run.

The Mesh Config target is **1.3.0 (7)**: `MARKETING_VERSION` is the short version, `CURRENT_PROJECT_VERSION` is the build number. Settings shows `Version 1.3.0 (7)` from the app bundle, and the Apply screen repeats that line. After you pull and Run, those screens should show this number.

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
| Apply | Pick a profile, pick Tracker or Gateway, scan, apply, verify, then next radio or done. |
| Settings | Installed version, default region and display units for new profiles, last profile, and the limits below. |

Function is asked for every radio:

- **Tracker** (default) — position source. Role is still asked: **TAK Tracker** (standalone, no ATAK end-user device on this phone) or **TAK** (paired to a phone that will run ATAK or iTAK plus the Meshtastic app’s Local TAK Server). The MQTT module on this radio is turned off.
- **Gateway** — Heltec-style node, for example a Heltec V3. Role is CLIENT. The radio joins a saved Wi-Fi network and the profile’s MQTT server. Wi-Fi disables Bluetooth after the radio reboots.

After a pass, **Next device** keeps the profile and clears the function back to Tracker so the next radio is an explicit choice. The app never auto-connects the next radio.

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

Gateway passwords use a second Keychain service, `com.meshconfig.gateway.secret`, with the same accessibility:

- MQTT password account: `mqtt-password.<profileUUID>`
- Wi-Fi password account: `wifi-psk.<networkUUID>`

The profile file stores those account strings only. A password is typed once and is not shown again. Duplicate profile does not copy either secret. Delete profile deletes them.

`FleetPSKStore.ensurePSK` runs before a channel write. If the key is missing, apply fails and does not send a partial channel.

Details: [docs/PSK_POLICY.md](docs/PSK_POLICY.md).

## Apply and verify

One active Bluetooth link. The next session waits until the current one is idle or disconnected.

Sync compares the radio to the profile and writes only what differs. Identical values are not sent, because rewriting them is what rebooted the radio over and over.

1. Connect and PhoneAPI handshake (`want_config_id` 69420). Drain FromRadio until config complete: every config section, module config, and channel. Then `get_owner` for the owner record and the 8-byte `session_passkey`.
2. Ensure the fleet key is in the Keychain.
3. Compare decoded fields, not serialized bytes. The long name is the callsign ATAK shows. The short name is the 4-byte mesh badge. Both are optional. If both fields are blank, the owner record is not sent. A non-blank field is sent only when it differs from the radio. If the fields were filled from the roster and not edited, the names read from the radio win and nothing is written for the owner. A LoRa, device, position, display, channel, network, or MQTT write is queued only when one of the fields this app owns in that section differs. Every TAK radio owns Ignore MQTT off, Ok to MQTT on, hop limit 3, transmit on, and channel uplink and downlink on. A tracker also owns MQTT disabled. A gateway also owns CLIENT, Wi-Fi on, the chosen SSID and Wi-Fi password, and the MQTT module (address, username, password, root, with encryption, JSON, TLS, proxy, and map reporting off). Field order, explicit proto3 zeros, and nested channel encoding do not count. The progress list and the “Fields that differed” log name each field, for example `device.role: TAK_TRACKER → TAK`. Password rows are `network.wifiPsk: •••• changed` and `mqtt.password: •••• changed`.
4. If nothing differs, write nothing and do not reboot. The progress line says **Already up to date**.
5. If something differs, one edit transaction: `begin_edit_settings`, the differing `set_owner` / `set_config` / `set_channel` / `set_module_config` messages, then `commit_edit_settings`. The radio reboots at most once. The progress line says how many settings will change.
6. After that reboot, wait up to 60 seconds for the link to drop, then up to 90 seconds for Bluetooth to come back and the handshake to finish. A tracker can beep late in that window. One missed connect does not end the wait. The handshake does not write again.
7. Read back and require every TAK check in `ProfileAcceptance.evaluate`. The long-name row must match only when this sync changed the long name. Otherwise the radio’s existing long name is accepted.
8. Disconnect. Show pass or fail. Failed checks are ids and labels only. A successful verify stores the long name and short name that are on the radio after the sync.

Power, Bluetooth, security, and module configs other than MQTT are read during the handshake and are not written. Network config is written only for a Gateway. The MQTT module is written for a tracker only to turn it off, and for a gateway with the server settings. Security bodies and passwords are not logged.

Full checklist and timeouts: [docs/APPLY_VERIFY.md](docs/APPLY_VERIFY.md). Screen contract: [docs/SCREENS_UX.md](docs/SCREENS_UX.md).

Profiles and the device roster are JSON files under Application Support (`fleet-profiles.json`, `configured-devices.json`). Saving a profile strips any exportable key field and locks the TAK template invariants (ShortTurbo, Ignore MQTT off, Ok to MQTT on, hop limit 3, transmit on, uplink and downlink, rebroadcast ALL, HAE altitude, precise location, replace default primary). Empty MQTT address, username, or root are filled with the OpenTAKServer defaults (`mcsctak.duckdns.org:8883`, `meshgw`, `opentakserver`).

## Radios

Bluetooth setup is the same path for:

- **Heltec WiFi LoRa 32 V3** — use Function **Gateway**. Mesh Config turns Wi-Fi on and points the MQTT module at OpenTAKServer. After that reboot the V3 may stop advertising Bluetooth, because Meshtastic disables Bluetooth while Wi-Fi is on. A gateway that is already on Wi-Fi may need Wi-Fi turned off before the phone can connect.
- **Heltec Mesh Node T114** — no Wi‑Fi. Use Function **Tracker**. Do not treat it as a gateway.
- **SenseCAP T1000-E** — tracker with GPS. Same Bluetooth config path.

ATAK or iTAK on the phone talks to the Local TAK Server inside the Meshtastic phone app, on that same phone. Packaging that server, flashing firmware, and programming a dock of radios over USB are out of scope here. V3 firmware is flashed from a computer. T114 and T1000-E updates are separate OTA paths.

## PhoneAPI protobufs

Live apply encodes and decodes the Meshtastic PhoneAPI admin subset in `MeshConfig/Apply/PhoneAPICodec.swift`: `ToRadio`, `FromRadio`, `MeshPacket`, `Data`, `AdminMessage`, `Config`, `ModuleConfig` (MQTT only), and `Channel`.

The field numbers match [meshtastic/protobufs](https://github.com/meshtastic/protobufs) commit `ad0bf31e82886d794334dcc62abb80da862a8ec7` (master, 2026-09-25). This repo does not vendor the protobuf tree or generated SwiftProtobuf sources. The codec keeps unknown fields inside a config body so a `set_config` or `set_module_config` does not wipe settings the profile does not own. LoRa transmit enable, hop limit, Ignore MQTT, and Ok to MQTT are owned fields.

Handshake writes `ToRadio.want_config_id` **69420** (firmware’s config-only nonce, so the node database is not downloaded), drains FromRadio until `config_complete_id` matches, then sends `AdminMessage.get_owner_request` to seed the 8-byte `session_passkey`. The drain is the full current config: config sections (device, position, power, network, display, LoRa, Bluetooth, security), module config, and channels. Network and the MQTT module body are kept for the diff and scrubbed when the link ends. Power, Bluetooth, security, and other module bodies are not retained and are not written back. Mutating admin messages include the passkey. It stays in memory for the connection and is never logged. The owner record is kept only so a later `set_owner` can change a name without clearing the node id, public key, or license flag.

Writes go out only inside `begin_edit_settings` (AdminMessage field 64) and `commit_edit_settings` (field 65). `set_owner` is field 32 and is sent only for a non-blank name that differs from the radio. The long name is limited to 24 UTF-8 bytes. The short name is limited to 4 UTF-8 bytes. A blank field is omitted, not cleared. LoRa, device, position, display, and (gateway only) network are `set_config` of a merged subsection, and only when a decoded field this app owns differs. The MQTT module is `set_module_config` (AdminMessage field 35, ModuleConfig field 1). A tracker write only clears `enabled`. A gateway write sets the server fields and clears encryption, JSON, TLS, proxy, and map reporting. The primary channel is one `set_channel` that keeps the radio’s channel id and replaces the name, 32-byte key, uplink, downlink, and precise-location bits (32) when one of those decoded fields differs. A matching value that the radio encoded with a different field order, an explicit zero, or a nested message our serializer would rewrite is left alone. Mutating admin messages set `want_response`. Firmware answers with a `Routing` packet (`error_reason` NONE, `request_id` equal to the packet id) after AdminModule accepts the write. A Bluetooth `want_ack` alone is not treated as success, because that ack can be generated before the admin module runs. A link drop before `commit_edit_settings` fails the sync. The commit itself reboots the radio once (`disableBluetooth`, then `saveChanges`). If the link is still up after the commit ack, the transport sends `reboot_seconds` so the session still reconnects once. An empty diff does not begin or commit, and it does not reboot. Enabling Wi-Fi disables Bluetooth, so a gateway may not come back for the read-back even when the save succeeded.

Read-back uses `get_owner`, `get_config`, and `get_channel` after that single reconnect, or immediately when nothing was written. The long-name row must match the callsign only when this sync changed it.

To regenerate after a protobuf change: check out that commit or a newer `meshtastic/protobufs` master, diff `meshtastic/mesh.proto`, `admin.proto`, `config.proto`, `module_config.proto`, `channel.proto`, and `portnums.proto` against the constants in `PhoneAPICodec.swift`, and update the codec. `PhoneAPICodec.selfCheck()` compares a few frames to bytes produced by `protoc` for this commit. `SyncDiff.selfCheck()` requires a radio that matches the profile except `device.role` to produce exactly that one field, even when the other sections use firmware field order and explicit zeros. It also requires a tracker that has drifted Ok to MQTT, Ignore MQTT, uplink, downlink, and MQTT enabled to list those fields, and a gateway to queue one network `set_config` and one MQTT `set_module_config` in the same plan. The second plan of either radio is empty. Debug lines must not contain the password bytes. A handshake refuses to write if either check fails.

## Known limits

CoreBluetooth scan, connect, and GATT discovery use the public Meshtastic service (`6BA1B218-15A8-461F-9FA8-5DCAE273EAFD`) and the ToRadio, FromRadio, and FromNum characteristics.

Managed-mode radios ignore local Bluetooth admin. This app does not flash firmware and does not configure a Local TAK Server. Wi-Fi is written only for a device whose function is Gateway. A Linux checkout still cannot run `xcodebuild`.

## Project layout

```
MeshConfig.xcodeproj
MeshConfig/
  MeshConfigApp.swift
  Info.plist
  Models/            FleetProfile, ConfiguredDevice
  Security/          FleetPSKStore and GatewaySecretStore (Keychain)
  Apply/             ApplySession, PhoneAPI codec, CoreBluetooth transport, DEBUG simulator
  Persistence/       profile and roster files
  UI/                Profiles, Devices, Apply, Settings
docs/                PSK, apply/verify, and screen specs
```
