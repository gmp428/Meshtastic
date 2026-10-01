# Mesh Config — iOS screens & fleet loop UX

Target: iPhone, iOS 17+. One BLE link. Dark-friendly, large tap targets (gloves/field).

## Navigation map

```
Tab / root
├── Profiles          (list + detail + edit)
├── Apply             (fleet loop entry)
└── Settings          (units default, region default, about)
```

Apply is the primary path in the field. Profiles is for prep.

---

## 1. Profiles list

**Purpose:** Saved fleet configs; seed with built-in TAK Tracker.

| Element | Behavior |
| --- | --- |
| Row | Name, subtitle “ShortTurbo · slot 50 · TAK Tracker default”, trailing chevron |
| Swipe | Duplicate; Delete (also deletes Keychain PSK for that profile id) |
| FAB / toolbar + | New profile (starts as copy of TAK defaults) |
| Empty | “Create TAK Tracker profile” primary button → `BuiltInProfiles.takTracker()` + `ensurePSK` |

**Don’t show:** raw PSK, Keychain account strings, protobuf enum ints.

---

## 2. Profile detail / edit

Sections matching the model: LoRa, Channel, Device defaults, Position, Display, Notes.

| Field | UI |
| --- | --- |
| Name | Text |
| Channel name | Text (warn if LongFast/ShortFast) |
| PSK | Status only: “Key in Keychain” / “Will generate on save”. Buttons: **Generate if missing**, **Rotate** (confirm: “All radios need re-apply”) |
| LoRa preset | Locked ShortTurbo on TAK template (advanced unlock later) |
| Slot | Stepper/number, default 50 |
| Ignore MQTT | Locked Off |
| Ok to MQTT | Locked On |
| Hop limit | Locked 3 |
| Transmit | Locked On |
| Default role | Segmented: TAK Tracker \| TAK |
| Rebroadcast | LOCAL_ONLY (fixed for TAK template) |
| Smart Position | Toggle |
| Altitude | Show “HAE (ALTITUDE)” read-only correct; no MSL toggle on TAK template |
| Units | Imperial / Metric |
| Save | Persists Codable profile; `ensurePSK` if needed |

**Server / MQTT** (profile-wide, used by the gateway; trackers only force the module off):

| Field | UI |
| --- | --- |
| Address | Text, default `mcsctak.duckdns.org:8883` |
| Username | Text, default `meshgw` |
| Root topic | Text, default `opentakserver` |
| Password | Secure field, saved once to the Keychain. After that, “Saved in Keychain” and Replace. Never shown again. |
| Encryption, JSON, TLS, proxy, map reporting | Locked Off |

**Wi-Fi for gateways** (not applied to trackers). Several networks can be saved. Apply uses the only network, or the one chosen for that gateway.

| Field | UI |
| --- | --- |
| SSID | Text, stored on the profile |
| Password | Secure field, Keychain account `wifi-psk.<networkUUID>`. Saved once. |
| Add / Remove | Add another network, or remove one and delete its Keychain item |

---

## 3. Apply — fleet loop (primary)

### 3a. Setup sheet (before scan)

1. **Profile** picker (default last-used)
2. **Function for this device** — Tracker (default) or Gateway. A gateway shows the only Wi-Fi network, or a picker when the profile has several, and a note that role is CLIENT and that Wi-Fi disables Bluetooth.
3. **Role for this device** — shown for a tracker only. Required segmented control:
   - **TAK Tracker** — standalone
   - **TAK** — this phone will run ATAK/iTAK + Local TAK Server
4. Short help under role (from `DeviceRole.shortHelp`)
5. **Name on TAK** — optional **long name** (the Meshtastic name ATAK shows as this radio’s callsign) and optional **short name** (the 4-byte mesh badge). Blank means leave that field alone. Both blank sends no name change. A roster row, Re-apply, or a scan hit that matches a roster peripheral fills the last synced names. Those fills are not edits. After connect, names read from the radio replace an unedited prefill.
6. Primary: **Scan for radios**
7. Footer shows the same bundle version as Settings (`Version <short> (<build>)`)

Gate: a tracker cannot scan until a profile and a role are set. A gateway cannot scan until a Wi-Fi network has an SSID and a saved password, and the MQTT password is in the Keychain. Any typed name must fit the byte limit. Blank names are allowed.

### 3b. Scan

- Live list of Meshtastic peripherals (name, RSSI)
- Pull to refresh; Stop scan
- Tap row → connect (one only)
- Banner if another session not idle: block

### 3c. Progress (single screen, step list)

Title: profile name, the long name that will be on the radio (or “Long name unchanged”), the mesh badge, role chip, and a one-line summary: **1 setting will change** or **Already up to date**.

Steps are only the work this sync will do (checkmarks / spinner / fail):

1. Connected & handshake  
2. Fleet PSK ready  
3. Compare with radio  
4. One row per field that differs, with the decoded change (`TAK_TRACKER → TAK`). No row for a section that already matches.  
5. Reboot, only when at least one field differs  
6. Verify  

Under the steps, **Fields that differed** lists ids such as `device.role: TAK_TRACKER → TAK`. Password rows say `•••• changed` and never the password. That list is safe to read on device: it has no PSK, Wi-Fi password, MQTT password, passkey, or public key. The result screen keeps the same list.

Footer: Cancel → disconnect, mark failed “cancelled”, return to setup.

### 3d. Result — Passed

- Green check, device id, profile, role
- Checklist all green (collapsed OK)
- Primary: **Next device** → back to Setup with **same profile**, function back to Tracker, role **and names cleared** (must pick again)
- Secondary: **Done** → Profiles or Apply idle

### 3e. Result — Failed

- Failed step + failed check ids/labels only (no secrets)
- Primary: **Retry this radio** (same peripheral if still visible)
- Secondary: **Skip / Next device**
- Tertiary: **Done**

---

## 4. Fleet loop rules (UX contract)

| Rule | Why |
| --- | --- |
| Function asked every device | Tracker vs gateway is a different radio job |
| Role asked every tracker | Stops TAK vs TAK_TRACKER mix-ups |
| Long name is per device, and optional | TAK callsign is per radio. Blank leaves the radio’s name alone. |
| Next device never auto-connects | Wrong board risk |
| One session at a time | BLE constraint |
| Rotate PSK confirms + copy “re-apply all” | Mesh split awareness |
| Success does not show key material | Security |

---

## 5. Settings

- Version at the top, read from the app bundle: `Version <MARKETING_VERSION> (<CURRENT_PROJECT_VERSION>)`
- Default region (US)
- Default display units
- Last profile id
- Link/about: Chaos Koalas ATAK guide (external)
- Note: firmware flash is out of band (V3 computer; T114/T1000-E OTA elsewhere)

---

## 6. Permissions & empty states

- Bluetooth off → system-style prompt to Settings
- No peripherals → “Power the radio, hold near phone”
- First launch → one-time: create TAK Tracker profile + explain one-PSK-per-fleet

---

## 7. Screen → types

| Screen | Owns |
| --- | --- |
| `ProfilesListView` | `[FleetProfile]` store |
| `ProfileEditorView` | `FleetProfile` + `FleetPSKStore` |
| `ApplySetupView` | profile id + function + `DeviceRole?` + optional Wi-Fi id + optional long name + optional short name |
| `ScanView` | CB scan |
| `ApplyProgressView` | `ApplySession` |
| `ApplyResultView` | checklist / failure |

---

## 8. Devices roster (remembered radios)

**New tab: Devices** (between Profiles and Apply, or after Apply).

On **successful verify**, upsert a `ConfiguredDevice`:
- displayName = the long name on the radio after the sync, when it has one
- `longName` and `shortName` from the radio after a passing verify (written value, or the value already there)
- peripheralID / nodeNum when known
- profileID + **role used for that apply**
- `lastStatus = configured`, `lastAppliedAt = now`

A failed attempt does not replace a long name that already verified.

### Devices list
| Row | Long name (TAK callsign), short-name badge, function chip (Tracker / Gateway), role chip, profile name, last applied, status badge |
| --- | --- |
| Status | Configured · Needs re-apply (role changed) · Failed · Pending |
| Tap | Device detail |
| Swipe | Remove from roster (does not factory-reset the radio) |

### Device detail
- Function picker (Tracker / Gateway). Gateway forces role CLIENT and can pick a saved Wi-Fi network when the profile has more than one. Changing function sets Needs re-apply and does not write Bluetooth.
- Role picker (TAK Tracker / TAK) for a tracker — changing sets `roleChangedNeedsReapply`
- Profile (read-only link, or switch profile with confirm)
- **Re-apply now** → Apply flow prefilled with this device’s profile, role, and last applied names; prefer reconnect by peripheralID. The names can still be edited before scan.
- Notes field

### Apply setup integration
- Optional: “Pick from roster” → skips role if already set, still confirms before connect
- After Next device: roster updates; unchanged radios stay listed

### Role change rule
Changing role in the UI **does not** write BLE by itself. It marks needs re-apply; user must run Apply (or Re-apply now) so Device config + verify run again. Other profile settings stay the same.
