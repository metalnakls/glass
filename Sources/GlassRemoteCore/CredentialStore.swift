import Foundation
import Security

public enum CredentialStoreError: Error, Equatable, Sendable {
    case keychainStatus(OSStatus)
    case encodingFailed
}

public protocol CredentialStore: Sendable {
    func password(for profileID: UUID) throws -> String
    func savePassword(_ password: String, for profileID: UUID) throws
    func deletePassword(for profileID: UUID) throws
}

public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "org.transmissionbt.glass.remote") {
        self.service = service
    }

    public func password(for profileID: UUID) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return ""
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainStatus(status)
        }
        guard let data = result as? Data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    public func savePassword(_ password: String, for profileID: UUID) throws {
        try deletePassword(for: profileID)
        guard !password.isEmpty else {
            return
        }
        guard let data = password.data(using: .utf8) else {
            throw CredentialStoreError.encodingFailed
        }

        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
            kSecValueData as String: data
        ]

        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychainStatus(status)
        }
    }

    public func deletePassword(for profileID: UUID) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychainStatus(status)
        }
    }
}

