import Foundation
import SyncEngine
import TernAI

@MainActor
enum AssistantWritingStyleBindings {
    static func make(app: AppModel, provider: any AIProvider) -> AssistantWritingStyleModel {
        AssistantWritingStyleModel(store: AssistantWritingStyleStores.makeDefault(), readSamples: { [weak app] account, isAuthorized in
            guard let app, let owner = app.mailbox?.account(id: account.id),
                  owner.account.email.lowercased() == account.email.lowercased(),
                  String(describing: ObjectIdentifier(owner)) == account.instanceID else { throw AssistantMailError.accessChanged }
            return try await owner.engine.assistantWritingSamples { [weak app, weak owner] in
                guard await isAuthorized() else { return false }
                return await MainActor.run {
                    guard let app, let owner, case .signedIn = app.phase,
                          app.mailbox?.account(id: account.id) === owner,
                          app.assistant.enabledAccountIDs.contains(account.id),
                          !app.accountsNeedingSignIn.contains(account.id) else { return false }
                    return owner.account.email.lowercased() == account.email.lowercased()
                }
            }
        }, analyze: { excerpts, model, date in
            try await WritingStyleAnalyzer(provider: provider).analyze(excerpts: excerpts, model: model, profiledAt: date)
        })
    }
}
