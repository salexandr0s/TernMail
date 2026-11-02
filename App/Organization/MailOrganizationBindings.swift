import Foundation
import GmailAPI
import SyncEngine
import TernAI

@MainActor
enum MailOrganizationBindings {
    static func access(app: AppModel, accountID: String, connection: SettingsAccountState) -> MailOrganizationAccess {
        let assistant = app.assistant.composeAccessRevision
        let instance: String?
        if case .signedIn = app.phase, let owner = app.mailbox?.account(id: accountID),
           !app.accountsNeedingSignIn.contains(accountID), assistant.scope.accountIDs.contains(accountID) {
            instance = String(describing: ObjectIdentifier(owner))
        } else { instance = nil }
        return MailOrganizationAccess(accountID: accountID, instanceID: instance,
            permissionRevision: assistant.revision, connectionRevision: assistant.scope.connectionRevision,
            modelID: assistant.scope.canUsePlan && assistant.modelReady ? assistant.modelID : nil,
            mailAccessEnabled: app.assistant.enabledAccountIDs.contains(accountID),
            canCreateFilters: connection.isEnabled(.gmailSettings) && app.settingsClient(for: accountID) != nil)
    }

    static func make(app: AppModel, accountID: String, connection: SettingsAccountState) -> MailOrganizationModel {
        let chatGPT = app.assistant.connection
        return MailOrganizationModel(access: { [weak app] in
            guard let app else {
                return .init(accountID: accountID, instanceID: nil, permissionRevision: 0,
                    connectionRevision: 0, modelID: nil, mailAccessEnabled: false, canCreateFilters: false)
            }
            return access(app: app, accountID: accountID, connection: connection)
        }, readSamples: { [weak app] expected, isAuthorized, progress in
            guard let app, let owner = app.mailbox?.account(id: accountID),
                  String(describing: ObjectIdentifier(owner)) == expected.instanceID,
                  await isAuthorized() else { throw AssistantMailError.accessChanged }
            return try await owner.engine.organizationSamples(isAuthorized: isAuthorized, progress: progress)
        }, analyze: { [weak chatGPT] samples, modelID, isAuthorized in
            guard await isAuthorized() else { throw AssistantMailError.accessChanged }
            let provider = scopedProvider(accessToken: { [weak chatGPT] in
                guard let chatGPT else { throw AIProviderError.signInRequired }
                return try await chatGPT.accessToken()
            }, isAuthorized: isAuthorized)
            let labels = samples.existingLabels.filter { !$0.isSystem }
            let names = Dictionary(labels.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
            let messages = samples.messages.map {
                OrganizationEmail(id: $0.messageID, threadID: $0.threadID, sender: $0.sender,
                    recipients: $0.recipients, subject: $0.subject, snippet: $0.snippet,
                    date: $0.date, isSent: $0.isSent, labelNames: $0.labelIDs.compactMap { names[$0] })
            }
            return try await MailOrganizationAnalyzer(provider: provider).analyze(
                messages: messages, existingLabelNames: labels.map(\.name), model: modelID)
        }, apply: { [weak app] categories, samples, isAuthorized in
            guard let app, let owner = app.mailbox?.account(id: accountID),
                  samples.accountID == accountID, await isAuthorized() else { throw AssistantMailError.accessChanged }
            try await connection.refresh()
            guard await isAuthorized(), app.mailbox?.account(id: accountID) === owner,
                  !categories.contains(where: \.createFilter) || connection.isEnabled(.gmailSettings) else {
                throw AssistantMailError.accessChanged
            }
            return try await owner.engine.applyOrganization(categories: categories, samples: samples,
                                                            isAuthorized: isAuthorized)
        }, status: { [weak app] receipt in
            guard let owner = app?.mailbox?.account(id: accountID), receipt.accountID == accountID else {
                throw AssistantMailError.accessChanged
            }
            return try await owner.engine.organizationApplicationStatus(receipt)
        })
    }

    /// Authorization belongs to this review, including across an asynchronous
    /// credential refresh. UI observation is not the network permission gate.
    nonisolated static func scopedProvider(accessToken: @escaping @Sendable () async throws -> String,
        isAuthorized: @escaping MailOrganizationModel.Authorized,
        transport: AIHTTPTransport = .live) -> ChatGPTProvider {
        ChatGPTProvider(accessToken: {
            try Task.checkCancellation()
            guard await isAuthorized() else { throw AssistantMailError.accessChanged }
            let token = try await accessToken()
            try Task.checkCancellation()
            guard await isAuthorized() else { throw AssistantMailError.accessChanged }
            return token
        }, transport: AIHTTPTransport { request in
            try Task.checkCancellation()
            guard await isAuthorized() else { throw AssistantMailError.accessChanged }
            return try await transport.send(request)
        })
    }
}
