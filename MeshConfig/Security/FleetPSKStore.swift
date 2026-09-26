import Foundation
import Security

// MARK: - Fleet PSK: generate once, store in Keychain, never log raw bytes

enum FleetPSKError: Error, Sendable {
    case keychainStatus(OSStatus)
    case invalidKeyLength(Int)
    case missingKey
    case profileHasNoAccount
}

extension FleetPSKError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            return "Keychain could not store or read the fleet PSK (status \(status))."
        case .invalidKeyLength:
            return "The fleet PSK in Keychain is not 32 bytes."
        case .missingKey:
            return "The fleet PSK is missing from Keychain."
        case .profileHasNoAccount:
            return "This profile has no Keychain PSK yet."
        }
    }
}

/// One AES-256 (32-byte) PSK per fleet profile, keyed by profile id in Keychain.
enum FleetPSKStore {
    private static let service = "com.meshconfig.fleet.psk"

    static func keychainAccount(for profileID: UUID) -> String {
        "fleet-psk.\(profileID.uuidString)"
    }

    /// Create a cryptographically random 32-byte key and store it. Fails if one already exists
    /// unless `overwrite` is true (explicit rotate flow only).
    @discardableResult
    static func generateAndStore(for profileID: UUID, overwrite: Bool = false) throws -> PSKReference {
        let account = keychainAccount(for: profileID)
        if try loadData(account: account) != nil, !overwrite {
            return PSKReference(keychainAccount: account, exportableBase64: nil)
        }
        var bytes = Data(count: 32)
        let status: OSStatus = bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, raw.count, base)
        }
        guard status == errSecSuccess else { throw FleetPSKError.keychainStatus(status) }
        try saveData(bytes, account: account, overwrite: overwrite)
        // Best-effort scrub of the temporary buffer. The Keychain item is the only copy we keep.
        for index in bytes.indices {
            bytes[index] = 0
        }
        return PSKReference(keychainAccount: account, exportableBase64: nil)
    }

    /// Bytes for BLE ChannelSettings.psk write. Caller must not log or persist outside Keychain.
    static func loadPSKData(for ref: PSKReference) throws -> Data {
        guard !ref.keychainAccount.isEmpty else { throw FleetPSKError.profileHasNoAccount }
        guard let data = try loadData(account: ref.keychainAccount) else { throw FleetPSKError.missingKey }
        guard data.count == 32 else { throw FleetPSKError.invalidKeyLength(data.count) }
        return data
    }

    /// Ensures the profile has a Keychain-backed PSK; generates if missing.
    static func ensurePSK(for profile: inout FleetProfile) throws {
        if profile.channel.pskRef.keychainAccount.isEmpty {
            profile.channel.pskRef = try generateAndStore(for: profile.id)
            profile.updatedAt = Date()
            return
        }
        if try loadData(account: profile.channel.pskRef.keychainAccount) == nil {
            profile.channel.pskRef = try generateAndStore(for: profile.id, overwrite: true)
            profile.updatedAt = Date()
        }
    }

    /// Rotate: new random key. Existing radios keep the old mesh until re-applied.
    static func rotatePSK(for profile: inout FleetProfile) throws {
        profile.channel.pskRef = try generateAndStore(for: profile.id, overwrite: true)
        profile.updatedAt = Date()
    }

    static func deletePSK(for profileID: UUID) throws {
        let account = keychainAccount(for: profileID)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FleetPSKError.keychainStatus(status)
        }
    }

    // MARK: Private Keychain

    private static func saveData(_ data: Data, account: String, overwrite: Bool) throws {
        if overwrite {
            try? deleteAccount(account)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query.filter { $0.key != kSecValueData as String } as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw FleetPSKError.keychainStatus(updateStatus) }
            return
        }
        guard status == errSecSuccess else { throw FleetPSKError.keychainStatus(status) }
    }

    private static func loadData(account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else {
            throw FleetPSKError.keychainStatus(status)
        }
        return data
    }

    private static func deleteAccount(_ account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw FleetPSKError.keychainStatus(status)
        }
    }
}
