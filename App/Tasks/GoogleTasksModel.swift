import Foundation
import GmailAPI
import MailStore
import Observation

/// Tasks are confirmed by Google before the local presentation changes. Read
/// generations keep delayed account/list responses out of the current sidebar.
@MainActor @Observable
final class GoogleTasksModel {
    private(set) var accounts: [AccountRecord] = []
    private(set) var hasLoadedAccounts = false
    private(set) var selectedAccountID: String?
    private(set) var selectedListID: String?
    var lists: [GoogleTaskList] = []
    var tasks: [GoogleTask] = [] {
        didSet {
            guard tasks != oldValue else { return }
            prepareTaskPresentation()
        }
    }
    private(set) var openTasks: [GoogleTask] = []
    private(set) var completedTasks: [GoogleTask] = []
    private var taskTitlesByID: [String: String] = [:]
    var isLoading = false
    var isConnecting = false
    var isCreating = false
    var busyTaskIDs: Set<String> = []
    var issue: GoogleTasksIssue?
    var errorMessage: String?
    var notice: String?
    var lastSyncedAt: Date?
    var pendingCreation: TaskCreationRequest?
    var creationStates: [String: TaskCreationState] = [:]

    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let loadAccounts: @MainActor () async throws -> [AccountRecord]
    @ObservationIgnored let service: @MainActor (String) -> (any TasksService)?
    @ObservationIgnored let enable: @MainActor (String) async throws -> Void
    @ObservationIgnored var lifecycle = 0
    @ObservationIgnored var readGeneration = 0
    @ObservationIgnored var accountGeneration = 0
    @ObservationIgnored var accountVersions: [String: Int] = [:]
    @ObservationIgnored var stopped = false
    @ObservationIgnored var uncertainReferences: [String: String]
    @ObservationIgnored var creationOwners: [String: String] = [:]
    @ObservationIgnored var confirmedTasks: [String: (location: GoogleTaskLocation, taskID: String)] = [:]
    private static let accountKey = "googleTasks.selectedAccount"
    static let uncertaintyKey = "googleTasks.uncertainReferences"

    convenience init(app: AppModel?, defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, loadAccounts: { [weak app] in
            try await app?.tasksAccounts() ?? []
        }, service: { [weak app] in app?.tasksService(for: $0) }, enable: { [weak app] id in
            guard let app else { throw GoogleTasksModelError.unavailable }
            try await app.enableTasks(for: id)
        })
    }

    init(defaults: UserDefaults, loadAccounts: @escaping @MainActor () async throws -> [AccountRecord],
         service: @escaping @MainActor (String) -> (any TasksService)?,
         enable: @escaping @MainActor (String) async throws -> Void) {
        self.defaults = defaults
        self.loadAccounts = loadAccounts
        self.service = service
        self.enable = enable
        selectedAccountID = defaults.string(forKey: Self.accountKey)
        uncertainReferences = defaults.dictionary(forKey: Self.uncertaintyKey) as? [String: String] ?? [:]
    }

    var selectedAccount: AccountRecord? { accounts.first { $0.id == selectedAccountID } }
    var selectedList: GoogleTaskList? { lists.first { $0.id == selectedListID } }
    var needsConnection: Bool {
        guard let id = selectedAccountID else { return false }
        return authorizedService(for: id) == nil || issue?.needsConnection == true
    }
    var canAdd: Bool { selectedListID != nil && !needsConnection && !isCreating && pendingCreation == nil && !stopped }
    var selectedLocation: GoogleTaskLocation? {
        guard let selectedAccountID, let selectedListID else { return nil }
        return GoogleTaskLocation(accountID: selectedAccountID, listID: selectedListID)
    }

    func parentTitle(for task: GoogleTask) -> String? {
        task.parent.flatMap { taskTitlesByID[$0] }
    }

    /// Keep row inputs in server order and prepare them only when task values change.
    private func prepareTaskPresentation() {
        var open: [GoogleTask] = []
        var completed: [GoogleTask] = []
        var titles: [String: String] = [:]
        for task in tasks {
            if titles[task.id] == nil { titles[task.id] = task.title }
            guard task.deleted != true else { continue }
            if task.isCompleted { completed.append(task) } else { open.append(task) }
        }
        if openTasks != open { openTasks = open }
        if completedTasks != completed { completedTasks = completed }
        if taskTitlesByID != titles { taskTitlesByID = titles }
    }

    func creationState(for request: TaskCreationRequest) -> TaskCreationState {
        let owner = request.source?.accountID ?? request.accountID ?? selectedAccountID
        if let recordedOwner = creationOwners[request.reference] ?? uncertainReferences[request.reference],
           let owner, recordedOwner != owner { return .idle }
        return creationStates[request.reference] ?? (uncertainReferences[request.reference] == nil ? .idle : .uncertain)
    }

    func selectAccount(_ id: String) {
        guard accounts.contains(where: { $0.id == id }), selectedAccountID != id else { return }
        readGeneration += 1
        isLoading = false
        selectedAccountID = id
        selectedListID = defaults.string(forKey: listKey(id))
        defaults.set(id, forKey: Self.accountKey)
        lists = []; tasks = []; issue = nil; errorMessage = nil; notice = nil; lastSyncedAt = nil
        Task { await refresh() }
    }

    func selectList(_ id: String) {
        guard lists.contains(where: { $0.id == id }), selectedListID != id, let accountID = selectedAccountID else { return }
        readGeneration += 1
        isLoading = false
        selectedListID = id
        defaults.set(id, forKey: listKey(accountID))
        tasks = []; errorMessage = nil; notice = nil; lastSyncedAt = nil
        // The picker already has this account's lists. Fetch the chosen list's
        // tasks directly; explicit and periodic refresh still discover lists.
        Task { await refresh(reloadLists: false) }
    }

    func refreshAccounts() async {
        accountGeneration += 1
        let generation = accountGeneration
        let revision = lifecycle
        do {
            let records = try await loadAccounts()
            guard generation == accountGeneration, revision == lifecycle, !stopped else { return }
            hasLoadedAccounts = true
            let removed = Set(accounts.map(\.id)).subtracting(records.map(\.id))
            for id in removed { purgeAccount(id) }
            accounts = records
            if !records.contains(where: { $0.id == selectedAccountID }) {
                selectedAccountID = records.first?.id
                selectedListID = selectedAccountID.flatMap { defaults.string(forKey: listKey($0)) }
                lists = []; tasks = []; issue = nil; lastSyncedAt = nil
            }
        } catch {
            guard generation == accountGeneration, revision == lifecycle, !stopped else { return }
            hasLoadedAccounts = true
            errorMessage = "Couldn't load your accounts. Try refreshing."
        }
    }

    func refresh(clearError: Bool = true, reloadLists: Bool = true) async {
        guard !stopped, !Task.isCancelled else { return }
        if clearError && pendingCreation == nil { errorMessage = nil }
        await refreshAccounts()
        guard !stopped, let accountID = selectedAccountID, let client = authorizedService(for: accountID) else { return }
        readGeneration += 1
        let generation = readGeneration
        let revision = lifecycle
        let access = accountVersions[accountID, default: 0]
        isLoading = true
        defer { if generation == readGeneration { isLoading = false } }
        do {
            let fetchedLists = if reloadLists || lists.isEmpty {
                try await client.allTaskLists()
            } else {
                lists
            }
            guard currentRead(generation, lifecycle: revision, accountID: accountID, access: access) else { return }
            lists = fetchedLists
            let preferred = selectedListID ?? defaults.string(forKey: listKey(accountID))
            let listID = fetchedLists.first { $0.id == preferred }?.id ?? fetchedLists.first?.id
            selectedListID = listID
            guard let listID else { tasks = []; issue = nil; lastSyncedAt = .now; return }
            defaults.set(listID, forKey: listKey(accountID))
            let fetched = try await client.allTasks(listID: listID)
            guard currentRead(generation, lifecycle: revision, accountID: accountID, access: access), selectedListID == listID else { return }
            tasks = fetched
            issue = nil
            lastSyncedAt = .now
            let hadPendingCreation = pendingCreation != nil
            reconcileMarkers(fetched, accountID: accountID, listID: listID)
            if hadPendingCreation && pendingCreation == nil { errorMessage = nil }
        } catch {
            guard currentRead(generation, lifecycle: revision, accountID: accountID, access: access) else { return }
            issue = GoogleTasksIssue(error)
        }
    }

    func connect() async {
        guard !isConnecting, let accountID = selectedAccountID else { return }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            try await enable(accountID)
            guard !stopped else { return }
            await refresh()
        } catch {
            guard selectedAccountID == accountID, !stopped else { return }
            errorMessage = "Google Tasks wasn't connected. Try again and allow Tasks access."
        }
    }

    func invalidateAccount(_ accountID: String) {
        accountVersions[accountID, default: 0] += 1
        if selectedAccountID == accountID {
            readGeneration += 1
            lists = []; tasks = []; isLoading = false; lastSyncedAt = nil
        }
    }

    func removeAccount(_ accountID: String) async {
        purgeAccount(accountID)
        accounts.removeAll { $0.id == accountID }
        if selectedAccountID == accountID {
            selectedAccountID = accounts.first?.id
            selectedListID = nil
            await refresh()
        }
    }

    func stop() {
        stopped = true
        lifecycle += 1
        readGeneration += 1
        isLoading = false
    }

    func resume() { stopped = false }

    func dismissPendingCreation() { pendingCreation = nil; errorMessage = nil }

    func showDestination(accountID: String, lists values: [GoogleTaskList], listID: String, tasks valuesTasks: [GoogleTask]) {
        guard selectedAccountID == accountID else { return }
        readGeneration += 1
        isLoading = false
        lists = values
        selectedListID = listID
        defaults.set(listID, forKey: listKey(accountID))
        tasks = valuesTasks
        issue = nil
    }

    func listKey(_ accountID: String) -> String { "googleTasks.selectedList." + accountID }

    func currentRead(_ generation: Int, lifecycle revision: Int, accountID: String, access: Int) -> Bool {
        generation == readGeneration && revision == lifecycle && selectedAccountID == accountID
            && validAccount(accountID, access: access) && !Task.isCancelled
    }

    func validAccount(_ accountID: String, access: Int) -> Bool {
        !stopped && accountVersions[accountID, default: 0] == access
            && accounts.contains(where: { $0.id == accountID }) && authorizedService(for: accountID) != nil
    }

    func authorizedService(for accountID: String) -> (any TasksService)? {
        guard let account = accounts.first(where: { $0.id == accountID }),
              account.enabledFeatures.contains(AccountFeature.tasks.rawValue),
              GoogleScopes.isCovered(.tasks, by: Set(account.grantedScopes)) else { return nil }
        return service(accountID)
    }

    func taskIsBusy(_ task: GoogleTask) -> Bool {
        guard let selectedLocation else { return false }
        return busyTaskIDs.contains(busyKey(task.id, location: selectedLocation))
    }

    func busyKey(_ taskID: String, location: GoogleTaskLocation) -> String {
        [location.accountID, location.listID, taskID].joined(separator: "\u{0}")
    }

    func reconcileMarkers(_ values: [GoogleTask], accountID: String, listID: String) {
        let location = GoogleTaskLocation(accountID: accountID, listID: listID)
        let liveIDs = Set(values.filter { $0.deleted != true }.map(\.id))
        for (reference, saved) in confirmedTasks where saved.location == location && !liveIDs.contains(saved.taskID) {
            creationStates[reference] = nil
            confirmedTasks[reference] = nil
        }
        for task in values where task.deleted != true {
            for line in (task.notes ?? "").components(separatedBy: .newlines) where line.hasPrefix("Tern task reference: ") {
                let reference = String(line.dropFirst("Tern task reference: ".count))
                guard reference.count == 64 else { continue }
                if let owner = creationOwners[reference] ?? uncertainReferences[reference], owner != accountID { continue }
                creationStates[reference] = .added
                creationOwners[reference] = accountID
                confirmedTasks[reference] = (location, task.id)
                uncertainReferences[reference] = nil
                if pendingCreation?.reference == reference { pendingCreation = nil }
            }
        }
        defaults.set(uncertainReferences, forKey: Self.uncertaintyKey)
    }

    private func purgeAccount(_ accountID: String) {
        invalidateAccount(accountID)
        if pendingCreation?.source?.accountID == accountID || pendingCreation?.accountID == accountID { pendingCreation = nil }
        for reference in creationOwners.filter({ $0.value == accountID }).map(\.key) {
            creationStates[reference] = nil; creationOwners[reference] = nil
            confirmedTasks[reference] = nil
        }
        uncertainReferences = uncertainReferences.filter { $0.value != accountID }
        defaults.set(uncertainReferences, forKey: Self.uncertaintyKey)
        defaults.removeObject(forKey: listKey(accountID))
    }
}
