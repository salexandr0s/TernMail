import Foundation

/// An address the account may forward mail to. Adding and verifying one
/// happens in Gmail.
public struct ForwardingAddress: Decodable, Sendable, Equatable {
    /// Gmail uses the same verification states for send-as and forwarding addresses.
    public typealias VerificationStatus = SendAsIdentity.VerificationStatus

    public let forwardingEmail: String
    public let verificationStatus: VerificationStatus

    /// Whether a filter can forward to this address yet.
    public var isAccepted: Bool { verificationStatus == .accepted }

    enum CodingKeys: String, CodingKey {
        case forwardingEmail, verificationStatus
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        forwardingEmail = try container.decode(String.self, forKey: .forwardingEmail)
        verificationStatus = try container.decodeIfPresent(VerificationStatus.self, forKey: .verificationStatus) ?? .unspecified
    }
}

extension GmailClient {
    /// `settings.forwardingAddresses.list`, which `gmail.modify` allows. Gmail
    /// returns them all at once, with no paging.
    public func forwardingAddresses() async throws -> [ForwardingAddress] {
        let list: ForwardingAddressList = try decode(await send(.get("settings/forwardingAddresses")))
        return list.forwardingAddresses ?? []
    }
}

private struct ForwardingAddressList: Decodable {
    let forwardingAddresses: [ForwardingAddress]?
}
