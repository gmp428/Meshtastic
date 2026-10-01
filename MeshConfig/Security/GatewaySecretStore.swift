import Foundation
import Security

enum GatewaySecretError: Error, Sendable {
    case keychainStatus(OSStatus)
    case emptySecret
}

extension GatewaySecretError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            return "Keychain could not store or read a gateway secret (status \(status))."
        case .emptySecret:
            return "Enter the Wi-Fi or MQTT password before saving it."
        }
    }
}

/// Wi-Fi and MQTT passwords for a gateway. Profile JSON stores the Keychain account only.
/// Callers must not log the bytes these methods return.
enum GatewaySecretStore {
    private static let service = "com.meshconfig.gateway.secret"

    static func mqttAccount(profileID: UUID) -> String {
        "mqtt-password.\(profileID.uuidString)"
    }

    static func wifiAccount(networkID: UUID) -> String {
        "wifi-psk.\(networkID.uuidString)"
    }

    static func save(_ secret: Data, account: String) throws {
        guard !secret.isEmpty else { throw GatewaySecretError.emptySecret }
        try delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw GatewaySecretError.keychainStatus(status) }
    }

    /// Nil when this phone has no item for the account. The bytes are the password. Do not log them.
    static func load(account: String) throws -> Data? {
        guard !account.isEmpty else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw GatewaySecretError.keychainStatus(status) }
        return result as? Data
    }

    static func delete(account: String) throws {
        guard !account.isEmpty else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GatewaySecretError.keychainStatus(status)
        }
    }

    static func deleteAll(for profile: FleetProfile) throws {
        try delete(account: profile.mqtt.passwordRef.keychainAccount)
        for network in profile.wifiNetworks {
            try delete(account: network.pskRef.keychainAccount)
        }
    }
}
