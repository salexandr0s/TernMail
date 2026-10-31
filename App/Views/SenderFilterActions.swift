import Foundation
import GmailAPI
import MailStore
import MessageContent
import SwiftUI

struct SenderFilterRequest: Identifiable {
    let id = UUID()
    let accountID: String
    let criteria: GmailFilter.Criteria
}

enum SenderFilterRules {
    /// Unblock must never remove a more complex filter made in Gmail.
    static func blockedAddress(_ filter: GmailFilter) -> EmailAddress? {
        guard let from = filter.criteria.from else { return nil }
        let addresses = EmailAddress.parseList(from)
        guard addresses.count == 1, let address = addresses.first, address.isValid,
              from.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == address.normalized,
              Set(filter.action.addLabelIds ?? []) == ["TRASH"], (filter.action.removeLabelIds ?? []).isEmpty,
              filter.action.forward == nil,
              filter.criteria.to == nil, filter.criteria.subject == nil, filter.criteria.query == nil,
              filter.criteria.negatedQuery == nil, filter.criteria.hasAttachment != true,
              filter.criteria.excludeChats != true, filter.criteria.size == nil else { return nil }
        return address
    }
}

extension MailTriageModel {
    func createFilter(from message: MessageRecord) {
        let sender = EmailAddress.parseList(message.sender).first?.address
        let recipient = EmailAddress.parseList(message.recipients).first?.address
        filterRequest = SenderFilterRequest(accountID: message.accountID,
            criteria: .init(from: sender, to: recipient, subject: message.subject.isEmpty ? nil : message.subject))
    }

    func createFilter(from address: EmailAddress, accountID: String) {
        filterRequest = SenderFilterRequest(accountID: accountID, criteria: .init(from: address.address))
    }
}

extension MailboxModel {
    func blockSender(_ address: EmailAddress, accountID: String, app: AppModel) async {
        guard address.isValid, let owner = account(id: accountID) else { return }
        do {
            let stored = try await accountStore?.accounts().first { $0.id == accountID }
            if stored?.enabledFeatures.contains(AccountFeature.gmailSettings.rawValue) != true
                || stored.map({ GoogleScopes.isCovered(.gmailSettings, by: $0.grantedScopes) }) != true {
                guard let grant = try await app.enableFeature(.gmailSettings, for: accountID),
                      grant.features.contains(.gmailSettings) else { return }
            }
            guard account(id: accountID) === owner else { return }
            let filter = GmailFilter(criteria: .init(from: address.normalized), action: .init(addLabelIds: [SystemLabel.trash]))
            queueUndoable("Block Sender", confirmation: "Sender blocked for new messages", in: owner) { engine in
                try await engine.createFilter(filter)
            }
        } catch {
            notice = Notice(message: "Couldn't block this sender. Turn on Gmail Settings for the account and try again.", isError: true)
        }
    }
}

struct SenderFilterReview: View {
    let request: SenderFilterRequest
    let app: AppModel
    @State private var model: SettingsModel
    @State private var isEnabling = false
    @State private var error: String?

    init(request: SenderFilterRequest, app: AppModel) {
        self.request = request
        self.app = app
        _model = State(initialValue: SettingsModel(accountID: request.accountID, app: app))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasEditPermission {
                HStack(spacing: Tokens.Space.s3) {
                    Text("Turn on Gmail Settings to save this filter.").font(.callout)
                    Button("Enable Gmail Settings") { Task { await enable() } }.disabled(isEnabling)
                    if isEnabling { ProgressView().controlSize(.small) }
                }
                .padding(Tokens.Space.s3)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(Tokens.Status.error)
                    .padding(Tokens.Space.s3)
            }
            FilterEditorSheet(model: model, original: nil, initialCriteria: request.criteria)
        }
        .task {
            await model.load()
            await model.watchQueue()
        }
    }

    private func enable() async {
        isEnabling = true
        defer { isEnabling = false }
        do {
            _ = try await app.enableFeature(.gmailSettings, for: request.accountID)
            await model.load()
        } catch { self.error = "Couldn't enable Gmail Settings. Try again." }
    }
}
