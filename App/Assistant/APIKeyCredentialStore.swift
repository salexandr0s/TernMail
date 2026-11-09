import Foundation
import Security
import TernAI

@MainActor
protocol APIKeyCredentialStore {
    func load(for service: AIService) async throws -> String?
    func save(_ key: String, for service: AIService) async throws
    func remove(for service: AIService) async throws
    func isDisconnected(_ service: AIService) -> Bool
    func setDisconnected(_ disconnected: Bool, for service: AIService)
}

struct APIKeyStorageError: Error, LocalizedError {
    var errorDescription: String? {
        "Tern could not access the API key in Keychain. Allow Keychain access and try again."
    }
}

/// Test hosts and synthetic previews never read the user's API credentials.
@MainActor
final class VolatileAPIKeyCredentialStore: APIKeyCredentialStore {
    private var keys: [AIService: String]
    private var disconnected: Set<AIService> = []
    init(keys: [AIService: String] = [:]) { self.keys = keys }
    func load(for service: AIService) -> String? { keys[service] }
    func save(_ key: String, for service: AIService) { keys[service] = key }
    func remove(for service: AIService) { keys[service] = nil }
    func isDisconnected(_ service: AIService) -> Bool { disconnected.contains(service) }
    func setDisconnected(_ value: Bool, for service: AIService) {
        if value { disconnected.insert(service) } else { disconnected.remove(service) }
    }
}

@MainActor
struct KeychainAPIKeyCredentialStore: APIKeyCredentialStore {
    func isDisconnected(_ service: AIService) -> Bool {
        UserDefaults.standard.bool(forKey: Self.disconnectedKey(service))
    }

    func setDisconnected(_ disconnected: Bool, for service: AIService) {
        UserDefaults.standard.set(disconnected, forKey: Self.disconnectedKey(service))
    }

    func load(for service: AIService) async throws -> String? {
        guard service.usesAPIKey else { throw APIKeyStorageError() }
        return try await KeychainIO.perform {
            var request = Self.query(service)
            request[kSecReturnData] = true
            request[kSecMatchLimit] = kSecMatchLimitOne
            var value: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &value)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = value as? Data, data.count <= 16_384,
                  let key = String(data: data, encoding: .utf8) else { throw APIKeyStorageError() }
            return key
        }
    }

    func save(_ key: String, for service: AIService) async throws {
        guard service.usesAPIKey else { throw APIKeyStorageError() }
        try await KeychainIO.perform {
            let query = Self.query(service)
            let data = Data(key.utf8)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData] = data
                guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw APIKeyStorageError() }
            } else if status != errSecSuccess { throw APIKeyStorageError() }
        }
    }

    func remove(for service: AIService) async throws {
        guard service.usesAPIKey else { throw APIKeyStorageError() }
        try await KeychainIO.perform {
            let status = SecItemDelete(Self.query(service) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw APIKeyStorageError() }
        }
    }

    private static func disconnectedKey(_ service: AIService) -> String {
        "assistant.apiKeyDisconnected." + service.rawValue
    }

    nonisolated private static func query(_ service: AIService) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: AppIdentity.keychainService(.apiKey), kSecAttrAccount: service.rawValue]
    }
}
