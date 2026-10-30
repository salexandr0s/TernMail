import Foundation
import Security

/// One atomic record keeps registration and pending token rotations together.
@MainActor
protocol AIConnectionStore {
    func load() throws -> Data?
    func save(_ data: Data) throws
    var isDisconnected: Bool { get }
    func setDisconnected(_ disconnected: Bool)
}

/// Synthetic previews and injected tests never read the user's connection.
@MainActor
final class VolatileAIConnectionStore: AIConnectionStore {
    private var data: Data?
    private(set) var isDisconnected = false
    init(data: Data? = nil) { self.data = data }
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
    func setDisconnected(_ disconnected: Bool) { isDisconnected = disconnected }
}

struct AIKeychainFailure: Error, LocalizedError {
    var errorDescription: String? {
        "Tern could not access the ChatGPT connection in Keychain. Allow Keychain access and try again."
    }
}

@MainActor
struct AIKeychainStore: AIConnectionStore {
    // This nonsecret marker stops a failed Keychain clear from restoring access
    // after relaunch. Credentials still live only in Keychain.
    var isDisconnected: Bool { UserDefaults.standard.bool(forKey: "chatGPTLocallyDisconnected") }
    func setDisconnected(_ disconnected: Bool) {
        UserDefaults.standard.set(disconnected, forKey: "chatGPTLocallyDisconnected")
    }

    private var query: [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: "dev.tern.mail.chatgpt",
         kSecAttrAccount: "connection"]
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData] = true
        request[kSecMatchLimit] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw AIKeychainFailure() }
        return data
    }

    func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData] = data
            // Match the existing Google credential store: the login keychain
            // also works with Tern's locally signed development builds.
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw AIKeychainFailure() }
        } else if status != errSecSuccess {
            throw AIKeychainFailure()
        }
    }
}
