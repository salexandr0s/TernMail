import Foundation

@objc protocol ClaudeCLIHelperProtocol {
    func status(_ requestID: String, withReply reply: @escaping @Sendable (Data) -> Void)
    func login(_ requestID: String, withReply reply: @escaping @Sendable (Data) -> Void)
    func submitLoginCode(_ code: String, requestID: String, withReply reply: @escaping @Sendable (Data) -> Void)
    func run(_ request: Data, requestID: String, withReply reply: @escaping @Sendable (Data) -> Void)
    func cancel(_ requestID: String)
}

@objc protocol ClaudeCLIClientProtocol {
    func receive(_ line: Data, requestID: String)
}

struct ClaudeCLIHelperReply: Codable, Sendable {
    let success: Bool
    let errorCode: String?

    init(success: Bool, errorCode: String? = nil) {
        self.success = success; self.errorCode = errorCode
    }
}

struct ClaudeCLIStatus: Codable, Equatable, Sendable {
    let available: Bool
    let version: String?
    let loggedIn: Bool
    let authMethod: String?
    let subscriptionType: String?
    let accountFingerprint: String?
    let errorCode: String?

    init(available: Bool, version: String? = nil, loggedIn: Bool = false,
         authMethod: String? = nil, subscriptionType: String? = nil, accountFingerprint: String? = nil, errorCode: String? = nil) {
        self.available = available; self.version = version; self.loggedIn = loggedIn
        self.authMethod = authMethod; self.subscriptionType = subscriptionType; self.accountFingerprint = accountFingerprint
        self.errorCode = errorCode
    }
}

/// The helper checks the connection accepted by Tern before starting inference.
struct ClaudeCLIHelperRunRequest: Codable, Sendable {
    let request: Data
    let expectedAccountFingerprint: String
    let expectedAuthMethod: String?
    let expectedSubscriptionType: String?
}
