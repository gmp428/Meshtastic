# BLE apply → verify → next (iOS, one link at a time)

## Constraints

- **One active BLE connection.** Never connect a second radio until the current session reaches `disconnected` (success or failed-and-cleaned-up).
- **Same `FleetProfile` + Keychain PSK** for every radio that should share the mesh.
- **Function is chosen per device** at session start: Tracker (default) or Gateway.
- **Role is chosen per tracker**: `TAK` (phone + ATAK/iTAK) vs `TAK_TRACKER` (standalone). A gateway is always `CLIENT`.
- **Names are chosen per device** at session start. They are not a fleet-wide setting. **Long name** is the Meshtastic name ATAK shows as the callsign / PLI name (24 UTF-8 bytes). **Short name** is the 4-byte mesh badge. A blank field is left unchanged. Both blank sends no owner change. A non-blank field is written only when it differs from the radio.
- PSK bytes leave Keychain only for the Channel write; never log them.
- Heltec V3 / T114 / T1000-E: BLE config path is the same. T114 has no Wi‑Fi and stays a Tracker. A V3 gateway gets Wi‑Fi; that disables Bluetooth after reboot.

## Session inputs

| Input | Source |
| --- | --- |
| Profile | Selected `FleetProfile` |
| Function | Tracker (default) or Gateway |
| Role | Tracker only. Explicit picker (default = `profile.defaultRole`). Gateway is CLIENT |
| Wi-Fi | Gateway only. One saved network, or a picker when the profile has several |
| MQTT password | Keychain, profile-wide. Required before a gateway scan |
| Long name | Optional text for this radio. TAK callsign. Blank keeps the radio’s current long name. Not stored on the profile. |
| Short name | Optional. Blank keeps the radio’s current short name. It is not derived from the long name. |
| Peripheral | User picks from scan (Meshtastic service UUID) |
| PSK | `FleetPSKStore.ensurePSK` then `loadPSKData` |

## State machine

```
idle
  → scanning
  → connecting
  → handshaking              # want_config drain of the full config, then get_owner
  → ensuringPSK
  → comparing                # diff; publish "N settings will change" or "Already up to date"
  → verifying                # when the diff is empty: no begin/commit, no reboot
  → applyingChanges          # when the diff is not empty: one begin/commit transaction
  → waitingReboot
  → reconnecting
  → handshaking              # read again; do not write again
  → verifying
  → succeeded | failed
  → disconnecting
  → disconnected → idle (ready for next radio)
```

Rewriting a section that already matches is what rebooted the radio once per section. Compare decoded fields first, not serialized bytes. A missing proto3 field and an explicit 0 are the same value. Nested channel bytes are compared by name, key, uplink, downlink, and precision. `commit_edit_settings` is the only reboot, and only when at least one write was queued. The Apply screen lists only the fields that differ, plus handshake, the key check, compare, reboot when needed, and verify. **Fields that differed** shows lines such as `device.role: TAK_TRACKER → TAK`. Password rows are exactly `network.wifiPsk: •••• changed` and `mqtt.password: •••• changed`. The password bytes are not printed.

## Per-section writes (protobuf intent)

### Owner (`User` via `AdminMessage.set_owner`)
- After handshake has seeded `session_passkey` and the current `User` has been read
- Send nothing when both name fields are blank, or when the user did not edit a roster prefill (the connected radio’s names win)
- `long_name` only when the field is non-blank and differs from the radio
- `short_name` only when the field is non-blank and differs from the radio
- Preserve the rest of the `User` returned by `get_owner` (node id, public key, license flag)
- The write is inside the edit transaction, not its own reboot

### LoRa (`Config.LoRa`)
- `use_preset = true`
- `modem_preset = SHORT_TURBO`
- `hop_limit = 3`
- `tx_enabled = true`
- `ignore_mqtt = false`
- `config_ok_to_mqtt = true` (required, or a gateway drops the packet)
- `channel_num` / frequency slot = profile (`50` for TAK ShortTurbo)
- region = profile region (US default)

### Device (`Config.Device`)
- Tracker: `role` = session role (`TAK` or `TAK_TRACKER`)
- Gateway: `role` = `CLIENT` (protobuf 0, written with force so the zero is not omitted)
- `rebroadcast_mode = LOCAL_ONLY`
- optional `tzdef` for standalones

### Position (`Config.Position`)
- `position_broadcast_smart_enabled` = profile (ops: true)
- `position_flags` = ALTITUDE | GEOIDAL_SEPARATION; **clear ALTITUDE_MSL**
- `gps_mode` = ENABLED when hardware has GPS (T1000-E / typical trackers)

### Display (`Config.Display`)
- units = imperial/metric from profile

### Channel
1. Read the current primary (or index 0). Keep its channel id. Do not mint a new id on every sync.
2. Merge name, AES-256 PSK (32 bytes from Keychain), precise location, and uplink/downlink.
3. `set_channel` only when the channel name, key, uplink, downlink, precision, or primary role differs. The write is inside the same edit transaction. Field order inside the channel settings does not count.

### Network (`Config.Network`) — Gateway only
- `wifi_enabled = true`
- `wifi_ssid` = the saved network chosen for this gateway
- `wifi_psk` = Keychain bytes for that network. Never logged. An empty password is not written (that would clear the radio).
- Trackers do not receive a network write.

### MQTT module (`ModuleConfig.mqtt` via `set_module_config`)
- Tracker: `enabled = false`. Address, username, password, and root on the radio are left alone.
- Gateway: `enabled = true`, `address` / `username` / `root` from the profile (defaults `mcsctak.duckdns.org:8883`, `meshgw`, `opentakserver`), password from the Keychain, `encryption_enabled = false`, `json_enabled = false`, `tls_enabled = false`, `proxy_to_client_enabled = false`, `map_reporting_enabled = false`. Map-report settings are not owned and are preserved.
- The MQTT write, when needed, is inside the same begin/commit as the other differing sections.

Sections the profile does not own (power, Bluetooth, security, module configs other than MQTT) are read in the `want_config` drain and not written. Network is written only for a Gateway.

## Reboot / reconnect

- No reboot when the diff is empty.
- One reboot after `commit_edit_settings` when any write was sent. A link drop before commit fails the sync.
- If the commit ack arrives and the link is still up, send `reboot_seconds` so the session still waits once.
- Re-match by **BLE peripheral identifier**.
- Timeouts (tuned for a T1000-E class tracker, which can beep and return to Bluetooth well after 20s):
  - first connect, radio already on: 15s
  - admin write ack: 10s
  - reboot disconnect (`rebootGrace`): 60s after the single commit
  - reconnect (`reconnectTimeout`): 90s, retrying connect and handshake until the radio is back
- A connect attempt that ends early, or a handshake that drops while the tracker is still booting, does not fail the session while time remains. A handshake that has already started is allowed to finish.
- The post-reboot handshake does not start another edit transaction.
- On timeout → `failed`; user can retry the session.

## Verify (`ProfileAcceptance.evaluate`)

After channel Send, read back and require **all** TAK checks green:

1. LoRa ShortTurbo  
2. Ignore MQTT off  
3. Ok to MQTT on  
4. Hop limit is 3  
5. Transmit is on  
6. Frequency slot matches profile  
7. Primary name private (not LongFast/ShortFast) and matches profile  
8. Primary PSK non-default (length/entropy check or “not default key” flag — **do not compare by logging bytes**)  
9. Precise location on  
10. Primary channel uplink on and downlink on  
11. Role matches session choice (CLIENT for a gateway)  
12. Long name matches the callsign when this sync changed it. When the long name was left alone, the row passes with the radio’s existing name.  
13. Rebroadcast LOCAL_ONLY  
14. Smart Position matches profile  
15. Position flags: ALTITUDE on, ALTITUDE_MSL off  
16. GEOIDAL_SEPARATION matches profile  
17. Tracker: MQTT module is off  
18. Gateway: Wi-Fi on and SSID matches; Wi-Fi password matches the Keychain (the row label does not include the bytes); MQTT on; address, username, and root match; MQTT password matches the Keychain; encryption, JSON, TLS, proxy, and map reporting are off  

A gateway that enabled Wi-Fi may not return on Bluetooth. Reconnect failure text says so. Confirm the node on the saved network and that OpenTAKServer received packets. Do not treat a missing BLE read-back as proof the save failed, and do not treat it as proof the save succeeded.

Any fail → `failed` with checklist; stay connected only long enough to show diffs, then disconnect.

## Fleet loop UX (contract)

1. User selects profile → picks function for **this** device. A tracker also picks a role. A gateway picks a Wi-Fi network when more than one is saved. Long and short name are optional. A roster row or Re-apply fills the last synced names without marking them edited. Scan.  
2. Connect → read the full config → show what will change → write the diff or skip → verify → show pass/fail.  
3. Disconnect. On success, store the long name and short name that are on the radio (the value just written, or the value that was already there).  
4. Prompt: **Next device** (same profile + ask function, role, and name again) or **Done**.  
5. Never auto-scan-connect the next radio without an explicit tap (avoids wrong-board flash of config).

## Out of scope for this flow

- Firmware flash (V3 = computer; T114/T1000-E = separate OTA path)
- Local TAK Server / ATAK data package (phone Meshtastic app / iTAK)
- USB hub multi-program
- Writing a second profile’s PSK onto a subset without an explicit profile switch

## Acceptance of the *app* flow itself

- Cannot start a second `ApplySession` while one is not `idle`/`disconnected`.
- PSK generate happens before first channel write; missing Keychain → hard fail, no partial channel.
- Success screen lists device identity + profile name + role applied; failure lists failed check ids only (no secrets).

## PhoneAPI / BLE transport (implementer’s contract)

Characteristics (Meshtastic Client API):

- **ToRadio** — write `ToRadio` protobufs (`wantConfigID`, packets)
- **FromRadio** — read until empty after want-config
- **FromNum** — notifications when FromRadio has data

### On every connect (including post-reboot)

1. GATT connect + discover services  
2. `ToRadio.wantConfigID` (nonce)  
3. Drain `FromRadio` until config-complete  
4. Seed **session_passkey** (e.g. `AdminMessage.get_owner_request` with `want_response`; newer firmware requires passkey on mutating admin)  
5. Diff, then either verify immediately or `begin_edit_settings` / differing sets / `commit_edit_settings`

### Mutating admin

Wrap `AdminMessage` in `MeshPacket` → `DataMessage` with `PortNum.ADMIN_APP`, include `session_passkey`, `want_response`. Write to ToRadio.

All mutating writes in one sync share one `begin_edit_settings` / `commit_edit_settings` pair so the radio reboots at most once. Channel, network, and the MQTT module are writes in that same pair when they differ. They are not a separate reboot.

### PSK on the wire

`loadPSKData` → pass `Data` (32 bytes) into `setPrimaryChannel` only. Do not copy into logs, breadcrumbs, or analytics.

See `ApplySession.swift` for the state machine and `MeshtasticBLETransport` protocol.
