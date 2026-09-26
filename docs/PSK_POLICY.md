# Fleet PSK policy (v1)

- **One generated AES-256 (32-byte) PSK per `FleetProfile`.**
- Stored only in **iOS Keychain** (`FleetPSKStore`), accessibility `AfterFirstUnlockThisDeviceOnly`.
- Account: `fleet-psk.<profileUUID>`; service: `com.meshconfig.fleet.psk`.
- Profile Codable JSON stores `PSKReference.keychainAccount` only — **never** raw key bytes.
- On first save / first apply: `FleetPSKStore.ensurePSK` generates if missing.
- All radios that should join the same mesh get that same Keychain-backed key at apply time.
- **No paste/import in v1.** Rotate = explicit `rotatePSK` (overwrite); then re-apply every device.
- Never log, print, or screenshot PSK material.
