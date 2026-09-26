# BLE apply → verify → next (iOS, one link at a time)

## Constraints

- **One active BLE connection.** Never connect a second radio until the current session reaches `disconnected` (success or failed-and-cleaned-up).
- **Same `FleetProfile` + Keychain PSK** for every radio that should share the mesh.
- **Role is chosen per device** at session start: `TAK` (phone + ATAK/iTAK) vs `TAK_TRACKER` (standalone).
- PSK bytes leave Keychain only for the Channel write; never log them.
- Heltec V3 / T114 / T1000-E: BLE config path is the same; do not assume Wi‑Fi on T114.

## Session inputs

| Input | Source |
| --- | --- |
| Profile | Selected `FleetProfile` |
| Role | Explicit picker (default = `profile.defaultRole`) |
| Peripheral | User picks from scan (Meshtastic service UUID) |
| PSK | `FleetPSKStore.ensurePSK` then `loadPSKData` |

## State machine

```
idle
  → scanning
  → connecting
  → ensuringPSK
  → readingBaseline          # optional; useful for “what was here”
  → applyingLoRa             # expect reboot
  → waitingReboot(lora)
  → reconnecting
  → applyingDevice           # role + LOCAL_ONLY; expect reboot
  → waitingReboot(device)
  → reconnecting
  → applyingPosition         # smart + HAE flags; expect reboot
  → waitingReboot(position)
  → reconnecting
  → applyingDisplay          # expect reboot
  → waitingReboot(display)
  → reconnecting
  → applyingChannel          # replace default primary; Send; NO reboot
  → verifying                # read-back vs ProfileAcceptance
  → succeeded | failed
  → disconnecting
  → disconnected → idle (ready for next radio)
```

**Why this section order:** Chaos Koalas documents reboot after LoRa / Device / Position / Display saves; Channel changes do **not** reboot but **must** be Sent. Apply reboot-heavy radio/device/position first so channel write lands on a stable post-reboot link, then verify once.

Batching note: if the Meshtastic BLE stack lets you set multiple Config sections before one reboot, the implementer may coalesce LoRa+Device+Position+Display into fewer reboot cycles — acceptance is identical. Default of this spec is **one section → wait reconnect** for predictable progress UI and easier failure isolation.

## Per-section writes (protobuf intent)

### LoRa (`Config.LoRa`)
- `use_preset = true`
- `modem_preset = SHORT_TURBO`
- `ignore_mqtt = true`
- `channel_num` / frequency slot = profile (`50` for TAK ShortTurbo)
- region = profile region (US default)

### Device (`Config.Device`)
- `role` = session role (`TAK` or `TAK_TRACKER`)
- `rebroadcast_mode = LOCAL_ONLY`
- optional `tzdef` for standalones

### Position (`Config.Position`)
- `position_broadcast_smart_enabled` = profile (ops: true)
- `position_flags` = ALTITUDE | GEOIDAL_SEPARATION; **clear ALTITUDE_MSL**
- `gps_mode` = ENABLED when hardware has GPS (T1000-E / typical trackers)

### Display (`Config.Display`)
- units = imperial/metric from profile

### Channel
1. If primary is default LongFast/ShortFast (or `replaceDefaultPrimary`): remove/replace primary.
2. Write primary: name, AES-256 PSK (32 bytes from Keychain), precise location on, uplink/downlink per profile.
3. **Send channel config to device** (required; no reboot).

## Reboot / reconnect

- After each reboot-triggering admin set: mark link lost expected; start reconnect timer.
- Re-match by **BLE peripheral identifier** first; fall back to advertised node name / MAC if the stack renumbers.
- Timeouts (starting points; tune on hardware):
  - connect: 15s
  - admin write ack: 10s
  - reboot disconnect: 5–20s
  - reconnect: 30s
- On timeout → `failed` with section id; leave radio as-is; user can retry session.

## Verify (`ProfileAcceptance.evaluate`)

After channel Send, read back and require **all** TAK checks green:

1. LoRa ShortTurbo  
2. Ignore MQTT on  
3. Frequency slot matches profile  
4. Primary name private (not LongFast/ShortFast) and matches profile  
5. Primary PSK non-default (length/entropy check or “not default key” flag — **do not compare by logging bytes**)  
6. Precise location on  
7. Role matches session choice  
8. Rebroadcast LOCAL_ONLY  
9. Smart Position matches profile  
10. Position flags: ALTITUDE on, ALTITUDE_MSL off  
11. GEOIDAL_SEPARATION matches profile  

Any fail → `failed` with checklist; stay connected only long enough to show diffs, then disconnect.

## Fleet loop UX (contract)

1. User selects profile → picks role for **this** device → Scan.  
2. Connect → apply → verify → show pass/fail.  
3. Disconnect.  
4. Prompt: **Next device** (same profile + ask role again) or **Done**.  
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
5. Only then `set_config` / `set_channel`

### Mutating admin

Wrap `AdminMessage` in `MeshPacket` → `DataMessage` with `PortNum.ADMIN_APP`, include `session_passkey`, `want_ack` (and response when needed). Write to ToRadio.

Channel: use the same path the Apple app’s `saveChannel` uses — set channel then ensure it is **Sent** to the radio (Chaos Koalas: device does not reboot for channel, but Send is required).

### PSK on the wire

`loadPSKData` → pass `Data` (32 bytes) into `setPrimaryChannel` only. Do not copy into logs, breadcrumbs, or analytics.

See `ApplySession.swift` for the state machine and `MeshtasticBLETransport` protocol.
