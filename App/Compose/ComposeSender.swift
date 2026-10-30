import Foundation
import MailStore
import MessageContent

/// A verified From address, qualified by account so shared aliases stay distinct.
struct ComposeSender: Identifiable, Equatable {
    let account: AccountRecord
    let identity: IdentityRecord

    var id: String { account.id + ":" + identity.lowercasedAddress }
    var address: String { identity.address }
    var label: String {
        EmailAddress(name: identity.displayName ?? account.displayName, address: address).displayString
    }

    static func choices(account: AccountRecord, identities: [IdentityRecord]) -> [ComposeSender] {
        var identities = identities.filter { $0.accountID == account.id && $0.canSend }
        // A newly connected or offline account can compose before its first identity sync.
        if !identities.contains(where: { $0.lowercasedAddress == account.email.lowercased() }) {
            identities.insert(IdentityRecord(
                accountID: account.id, address: account.email, displayName: account.displayName,
                isPrimary: true, fetchedAt: .distantPast
            ), at: 0)
        }
        return identities.map { ComposeSender(account: account, identity: $0) }
    }

    static func preferred(in choices: [ComposeSender], original: MessageRecord?, kind: LocalDraft.Kind) -> ComposeSender? {
        if kind == .reply || kind == .replyAll, let original {
            let recipients = EmailAddress.parseList(original.recipients) + EmailAddress.parseList(original.cc ?? "")
            for recipient in recipients {
                if let choice = choices.first(where: { $0.identity.lowercasedAddress == recipient.normalized }) {
                    return choice
                }
            }
        }
        return choices.first(where: { $0.identity.isDefault })
            ?? choices.first(where: { $0.identity.isPrimary }) ?? choices.first
    }

    func signature(for kind: LocalDraft.Kind) -> String? {
        kind == .new || account.signatureOnReplies ? identity.signatureHTML : nil
    }
}
