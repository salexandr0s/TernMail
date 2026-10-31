import Foundation
import Security

/// Security calls can wait for a system prompt. A dedicated queue keeps that
/// wait off the main actor and preserves the order of submitted operations.
enum KeychainIO {
    private static let queue = DispatchQueue(label: "dev.tern.keychain", qos: .userInitiated)

    static func perform<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }
}

/// Stores small secrets as generic passwords in the login keychain.
///
/// This uses the file-based keychain on purpose: the data protection keychain
/// requires a team-signed build, and local builds are signed ad hoc.
enum KeychainStore {
    private static let service = "dev.tern.mail.oauth"

    struct Failure: Error {
        let status: OSStatus
    }

    static func save(_ data: Data, account: String) async throws {
        try await KeychainIO.perform {
            let query = baseQuery(account: account)
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query
                item[kSecValueData] = data
                let added = SecItemAdd(item as CFDictionary, nil)
                guard added == errSecSuccess else { throw Failure(status: added) }
            } else if status != errSecSuccess {
                throw Failure(status: status)
            }
        }
    }

    static func load(account: String) async throws -> Data? {
        try await KeychainIO.perform {
            var query = baseQuery(account: account)
            query[kSecReturnData] = true
            query[kSecMatchLimit] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw Failure(status: status) }
            return result as? Data
        }
    }

    static func delete(account: String) async throws {
        try await KeychainIO.perform {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
        }
    }

    private static func baseQuery(account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }
}
