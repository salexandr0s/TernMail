import MailStore
import Observation

@MainActor @Observable
final class MailOrganizationSessions {
    @MainActor final class Session {
        let connection: SettingsAccountState
        let model: MailOrganizationModel
        private var observation: Task<Void, Never>?

        init(connection: SettingsAccountState, model: MailOrganizationModel) {
            self.connection = connection
            self.model = model
            observation = Task { [weak connection] in
                guard let connection, !Task.isCancelled else { return }
                try? await connection.refresh()
                guard !Task.isCancelled else { return }
                await connection.observe()
            }
        }

        deinit { observation?.cancel() }

        func stop() {
            observation?.cancel(); observation = nil
            model.clear()
        }
    }

    var selectedAccountID = ""
    @ObservationIgnored private var sessions: [String: Session] = [:]
    @ObservationIgnored private let accountIDs: @MainActor () -> [String]
    @ObservationIgnored private let makeSession: @MainActor (String) -> Session?

    init(accountIDs: @escaping @MainActor () -> [String],
         makeSession: @escaping @MainActor (String) -> Session?) {
        self.accountIDs = accountIDs
        self.makeSession = makeSession
        observeAccounts()
    }

    convenience init(app: AppModel) {
        self.init(accountIDs: { [weak app] in app?.mailbox?.accounts.map(\.account.id) ?? [] },
            makeSession: { [weak app] accountID in
                guard let app, let account = app.mailbox?.account(id: accountID)?.account else { return nil }
                let connection = SettingsAccountState(accountID: accountID, store: app.settingsAccountStore,
                                                      initial: account)
                return Session(connection: connection,
                    model: MailOrganizationBindings.make(app: app, accountID: accountID, connection: connection))
            })
    }

    func session(for accountID: String) -> Session? {
        guard accountIDs().contains(accountID) else { return nil }
        if let session = sessions[accountID] { return session }
        guard let session = makeSession(accountID) else { return nil }
        sessions[accountID] = session
        return session
    }

    func clear() {
        for session in sessions.values { session.stop() }
        sessions.removeAll()
        selectedAccountID = ""
    }

    private func observeAccounts() {
        let ids = withObservationTracking {
            accountIDs()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeAccounts() }
        }
        let available = Set(ids)
        for id in sessions.keys where !available.contains(id) {
            sessions.removeValue(forKey: id)?.stop()
        }
        if !available.contains(selectedAccountID) { selectedAccountID = ids.first ?? "" }
    }
}
