import GmailAPI
import MailStore
import Observation

/// Live configuration shared by permission controls and settings editors.
@MainActor @Observable
final class SettingsAccountState {
    let accountID: String
    private(set) var account: AccountRecord?
    @ObservationIgnored private let store: AccountStore?

    init(accountID: String, store: AccountStore?, initial: AccountRecord? = nil) {
        self.accountID = accountID
        self.store = store
        account = initial
    }

    func isEnabled(_ feature: AccountFeature) -> Bool {
        account.map { AccountFeature.named($0.enabledFeatures).contains(feature) } == true
    }

    func refresh() async throws {
        account = try await store?.accounts().first(where: { $0.id == accountID })
    }

    func observe() async {
        guard let store else { return }
        do {
            for try await account in store.accountChanges(id: accountID) {
                guard !Task.isCancelled else { return }
                self.account = account
            }
        } catch {
            // A read failure cannot leave a stale permission enabled.
            account = nil
        }
    }
}
