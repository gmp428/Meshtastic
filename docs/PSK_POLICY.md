# Fleet PSK policy (v1)

- **One generated AES-256 (32-byte) PSK per `FleetProfile`.**
- Stored only in **iOS Keychain** (`FleetPSKStore`), accessibility `AfterFirstUnlockThisDeviceOnly`.
- Account: `fleet-psk.<profileUUID>`; service: `com.meshconfig.fleet.psk`.
- Profile Codable JSON stores `PSKReference.keychainAccount` only — **never** raw key bytes.
- On first save / first apply: `FleetPSKStore.ensurePSK` generates if missing.
- All radios that should join the same mesh get that same Keychain-backed key at apply time.
- **No paste/import in v1.** Rotate = explicit `rotatePSK` (overwrite); then re-apply every device.
- Never log, print, or screenshot PSK material.

## Gateway secrets (same phone, separate service)

- Service: `com.meshconfig.gateway.secret`. Accessibility: `AfterFirstUnlockThisDeviceOnly`.
- MQTT password, entered once per profile: account `mqtt-password.<profileUUID>`.
- Wi-Fi password, entered once per saved network: account `wifi-psk.<networkUUID>`.
- Profile JSON stores `KeychainSecretRef.keychainAccount` only. Never the password.
- The password is not loaded back into the editor. Replace writes a new Keychain item.
- Duplicate profile clears both refs and gives each Wi-Fi row a new id. The user types the passwords again.
- Delete profile deletes the MQTT item and every Wi-Fi item for that profile.
- Fields that differed shows `•••• changed` for `network.wifiPsk` and `mqtt.password`. The bytes are not printed.
