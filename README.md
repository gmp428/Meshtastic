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

Bluetooth permission is requested when you scan. The usage string is `NSBluetoothAlwaysUsageDescription` in `MeshConfig/Info.plist`.

A Linux checkout cannot run `xcodebuild`. The project file is still a normal Xcode project (`project.pbxproj`, shared scheme, Swift sources).

### Try the loop without a radio

Debug builds have **Simulated radios (DEBUG)** on the Apply tab. That transport is compiled only with `#if DEBUG`. It is labeled DEBUG on every row. It walks handshake, the section order, reboot reconnects, channel send, and verify in the UI. It does not talk to hardware and it does not mean a protobuf admin write succeeded.

Release builds only include the CoreBluetooth transport.

## What the tabs do

| Tab | Role |
| --- | --- |
| Profiles | Saved fleet profiles. New profiles start from the TAK Tracker defaults. |
| Devices | Radios this phone has applied, or last attempted. |
| Apply | Pick a profile, pick a role, scan, apply, verify, then next radio or done. |
| Settings | Default region and display units for new profiles, last profile, and the limits below. |

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

Order, because LoRa, Device, Position, and Display reboot on save and Channel does not:

1. Connect and PhoneAPI handshake (`wantConfig`, drain FromRadio, seed `session_passkey`).
2. Ensure the fleet key is in the Keychain.
3. LoRa — preset ShortTurbo, Ignore MQTT, frequency slot from the profile (50 on the TAK template), region from the profile. Then reboot and reconnect.
4. Device — role chosen for this radio, rebroadcast LOCAL_ONLY, optional POSIX time zone. Then reboot and reconnect.
5. Position — smart position from the profile, `ALTITUDE` and `GEOIDAL_SEPARATION`, **not** `ALTITUDE_MSL`. Then reboot and reconnect.
6. Display — imperial or metric from the profile. Then reboot and reconnect.
7. Channel — remove the default LongFast/ShortFast primary, write the private primary (name, 32-byte key, precise location, uplink and downlink), and **Send**. No reboot.
8. Read back and require every TAK check in `ProfileAcceptance.evaluate`.
9. Disconnect. Show pass or fail. Failed checks are ids and labels only.

Full checklist and timeouts: [docs/APPLY_VERIFY.md](docs/APPLY_VERIFY.md). Screen contract: [docs/SCREENS_UX.md](docs/SCREENS_UX.md).

Profiles and the device roster are JSON files under Application Support (`fleet-profiles.json`, `configured-devices.json`). Saving a profile strips any exportable key field and locks the TAK template invariants (ShortTurbo, LOCAL_ONLY, HAE altitude, precise location, replace default primary).

## Radios

Bluetooth setup is the same path for:

- **Heltec WiFi LoRa 32 V3** — this board has Wi‑Fi hardware. Mesh Config does not use it. Meshtastic Wi‑Fi is not a native home TAK server.
- **Heltec Mesh Node T114** — no Wi‑Fi. Do not treat it as a Wi‑Fi node.
- **SenseCAP T1000-E** — tracker with GPS. Same Bluetooth config path.

ATAK or iTAK on the phone talks to the Local TAK Server inside the Meshtastic phone app, on that same phone. Packaging that server, flashing firmware, and programming a dock of radios over USB are out of scope here. V3 firmware is flashed from a computer. T114 and T1000-E updates are separate OTA paths.

## Known limits

CoreBluetooth scan, connect, and GATT discovery use the public Meshtastic service (`6BA1B218-15A8-461F-9FA8-5DCAE273EAFD`) and the ToRadio, FromRadio, and FromNum characteristics.

Admin protobuf writes are not encoded yet. After the link is up, handshake, `set_config`, channel Send, and read-back throw a clear error instead of reporting success. The DEBUG simulated transport is how you exercise the apply UI until Meshtastic protobufs are integrated.

## Project layout

```
MeshConfig.xcodeproj
MeshConfig/
  MeshConfigApp.swift
  Info.plist
  Models/            FleetProfile, ConfiguredDevice
  Security/          FleetPSKStore (Keychain)
  Apply/             ApplySession, CoreBluetooth transport, DEBUG simulator
  Persistence/       profile and roster files
  UI/                Profiles, Devices, Apply, Settings
docs/                PSK, apply/verify, and screen specs
```
