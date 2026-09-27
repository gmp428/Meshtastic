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
| Ignore MQTT | Toggle on |
| Default role | Segmented: TAK Tracker \| TAK |
| Rebroadcast | LOCAL_ONLY (fixed for TAK template) |
| Smart Position | Toggle |
| Altitude | Show “HAE (ALTITUDE)” read-only correct; no MSL toggle on TAK template |
| Units | Imperial / Metric |
| Save | Persists Codable profile; `ensurePSK` if needed |

---

## 3. Apply — fleet loop (primary)

### 3a. Setup sheet (before scan)

1. **Profile** picker (default last-used)
2. **Role for this device** — required segmented control:
   - **TAK Tracker** — standalone
   - **TAK** — this phone will run ATAK/iTAK + Local TAK Server
3. Short help under role (from `DeviceRole.shortHelp`)
4. **Name on TAK** — required **long name** (the Meshtastic name ATAK shows as this radio’s callsign) and optional **short name** (the 4-character mesh badge). Blank short name uses the first 4 characters of the long name. These are per radio, not a fleet setting.
5. Primary: **Scan for radios**
6. Footer shows the same bundle version as Settings (`Version <short> (<build>)`)

Gate: cannot scan until profile, role, and a valid long name are set.

### 3b. Scan

- Live list of Meshtastic peripherals (name, RSSI)
- Pull to refresh; Stop scan
- Tap row → connect (one only)
- Banner if another session not idle: block

### 3c. Progress (single screen, step list)

Title: profile name, TAK long name, mesh badge, role chip.

Steps (checkmarks / spinner / fail):

1. Connected & handshake  
2. Fleet PSK ready  
3. TAK long name (… reboot)  
4. LoRa (… reboot)  
5. Device role + rebroadcast (… reboot)  
6. Position (… reboot)  
7. Display (… reboot)  
8. Channel Send  
9. Verify  

Footer: Cancel → disconnect, mark failed “cancelled”, return to setup.

### 3d. Result — Passed

- Green check, device id, profile, role
- Checklist all green (collapsed OK)
- Primary: **Next device** → back to Setup with **same profile**, role **and names cleared** (must pick again)
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
| Role asked every device | Stops TAK vs TAK_TRACKER mix-ups |
| Long name asked every device | TAK callsign is per radio, not per fleet |
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
| `ApplySetupView` | profile id + `DeviceRole?` + long name + optional short name |
| `ScanView` | CB scan |
| `ApplyProgressView` | `ApplySession` |
| `ApplyResultView` | checklist / failure |

---

## 8. Devices roster (remembered radios)

**New tab: Devices** (between Profiles and Apply, or after Apply).

On **successful verify**, upsert a `ConfiguredDevice`:
- displayName = the applied long name
- `longName` and `shortName` from this apply
- peripheralID / nodeNum when known
- profileID + **role used for that apply**
- `lastStatus = configured`, `lastAppliedAt = now`

A failed attempt does not replace a long name that already verified.

### Devices list
| Row | Long name (TAK callsign), short-name badge, role chip (TAK / TAK Tracker), profile name, last applied, status badge |
| --- | --- |
| Status | Configured · Needs re-apply (role changed) · Failed · Pending |
| Tap | Device detail |
| Swipe | Remove from roster (does not factory-reset the radio) |

### Device detail
- Role picker (TAK Tracker / TAK) — changing sets `roleChangedNeedsReapply`
- Profile (read-only link, or switch profile with confirm)
- **Re-apply now** → Apply flow prefilled with this device’s profile, role, and last applied names; prefer reconnect by peripheralID. The names can still be edited before scan.
- Notes field

### Apply setup integration
- Optional: “Pick from roster” → skips role if already set, still confirms before connect
- After Next device: roster updates; unchanged radios stay listed

### Role change rule
Changing role in the UI **does not** write BLE by itself. It marks needs re-apply; user must run Apply (or Re-apply now) so Device config + verify run again. Other profile settings stay the same.
