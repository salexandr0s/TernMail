import Foundation

/// An account-qualified conversation reference. IDs stay opaque during routing.
public struct MailLink: Hashable, Codable, Sendable {
    public var accountID: String
    public var threadID: String
    public var messageID: String?

    public init(accountID: String, threadID: String, messageID: String? = nil) {
        self.accountID = accountID
        self.threadID = threadID
        self.messageID = messageID
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "tern", parts.host?.lowercased() == "conversation",
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { return nil }
        var fields: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard ["account", "thread", "message"].contains(item.name), fields[item.name] == nil,
                  let value = item.value, !value.isEmpty, value.utf8.count <= 512,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
            fields[item.name] = value
        }
        guard let account = fields["account"], let thread = fields["thread"] else { return nil }
        self.init(accountID: account, threadID: thread, messageID: fields["message"])
    }

    public var ternURL: URL? {
        var parts = URLComponents()
        parts.scheme = "tern"
        parts.host = "conversation"
        parts.queryItems = [URLQueryItem(name: "account", value: accountID), URLQueryItem(name: "thread", value: threadID)]
        if let messageID { parts.queryItems?.append(URLQueryItem(name: "message", value: messageID)) }
        return parts.url
    }

    /// authuser selects the mailbox by address rather than an unstable tab index.
    public func gmailURL(email: String) -> URL? {
        guard !email.isEmpty, !threadID.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "mail.google.com"
        parts.path = "/mail/u/"
        parts.queryItems = [URLQueryItem(name: "authuser", value: email)]
        parts.fragment = "all/" + threadID
        return parts.url
    }
}
