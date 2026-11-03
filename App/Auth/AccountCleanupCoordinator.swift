import Foundation
import MailStore

/// Cleanup and same-account sign-in share this queue. A new credential cannot
/// be saved while a retry still holds the right to delete the old credential.
@MainActor
final class AccountCleanupCoordinator {
    struct Operations {
        var removeAccount: @MainActor (String) async throws -> Void
        var removeCredentials: @MainActor (String) async throws -> Void
        var removeCache: @MainActor (String) async throws -> Void
        var removeWritingStyle: @MainActor (String) async throws -> Void
        var removeFile: @MainActor (URL) async throws -> Void = { url in
            try await Task.detached(priority: .utility) {
                do { try FileManager.default.removeItem(at: url) }
                catch let error as CocoaError where error.code == .fileNoSuchFile { return }
            }.value
        }
    }

    private let store: AccountStore
    private let downloadsRoot: URL
    private let outgoingRoot: URL?
    private let operations: Operations
    private var operation: Task<Void, Never>?

    init(store: AccountStore, downloadsRoot: URL, outgoingRoot: URL?, operations: Operations) {
        self.store = store
        self.downloadsRoot = downloadsRoot
        self.outgoingRoot = outgoingRoot
        self.operations = operations
    }

    /// The checkpoint commits before invalidation or any destructive operation.
    func remove(accountID: String, draftIDs: Set<String>,
                invalidateSession: @escaping @MainActor () async -> Void = {}) async throws -> Bool {
        try await serialized { [self] in
            let removal = try await store.beginAccountRemoval(accountID: accountID, draftIDs: draftIDs)
            await invalidateSession()
            return try await process(removal)
        }
    }

    /// Failures for one account do not stop cleanup of the others.
    func retryPending() async throws -> Bool {
        try await serialized { [self] in
            var complete = true
            for removal in try await store.pendingAccountRemovals() {
                if try await process(removal) == false { complete = false }
            }
            return complete
        }
    }

    /// Call before saving or adopting newly issued credentials. The app also
    /// serializes this call with its account changes through credential save.
    func prepareForSignIn(accountID: String) async throws {
        try await serialized { [self] in
            guard let removal = try await store.pendingAccountRemovals().first(where: { $0.accountID == accountID }) else { return }
            guard try await process(removal) else { throw AccountRemovalError.incomplete }
        }
    }

    private func process(_ removal: PendingAccountRemoval) async throws -> Bool {
        var completed = removal.completed
        for stage in PendingAccountRemoval.Stage.allCases where !completed.contains(stage) {
            do {
                switch stage {
                case .account: try await operations.removeAccount(removal.accountID)
                case .credentials: try await operations.removeCredentials(removal.accountID)
                case .cache: try await operations.removeCache(removal.accountID)
                case .writingStyle: try await operations.removeWritingStyle(removal.accountID)
                case .files: try await removeFiles(removal)
                }
                try await store.completeAccountRemovalStage(stage, removal: removal)
                completed.insert(stage)
            } catch {
                // A failed stage stays durable; independent cleanup still runs.
                continue
            }
        }
        guard completed == Set(PendingAccountRemoval.Stage.allCases) else { return false }
        try await store.finishAccountRemoval(removal)
        return true
    }

    private func removeFiles(_ removal: PendingAccountRemoval) async throws {
        var failed = false
        let accountFolder = try Self.managedChild(removal.accountID, within: downloadsRoot)
        var folders = [accountFolder]
        if !removal.draftIDs.isEmpty {
            guard let outgoingRoot else { throw AccountRemovalError.incomplete }
            folders += try removal.draftIDs.sorted().map { try Self.managedChild($0, within: outgoingRoot) }
        }
        for folder in folders {
            do { try await operations.removeFile(folder) }
            catch { failed = true }
        }
        if failed { throw AccountRemovalError.incomplete }
    }

    static func managedChild(_ component: String, within root: URL) throws -> URL {
        guard root.isFileURL, PendingAccountRemoval.validPathComponent(component) else { throw AccountRemovalError.invalidRecord }
        let base = root.standardizedFileURL
        let child = base.appending(path: component, directoryHint: .isDirectory).standardizedFileURL
        guard child.path != base.path, child.deletingLastPathComponent().path == base.path else {
            throw AccountRemovalError.invalidRecord
        }
        return child
    }

    /// Startup cleanup also covers a calendar cache whose model was never opened.
    /// An absent cache is complete; do not create a new database just to erase it.
    static func removeCalendarCache(accountID: String, at url: URL) async throws {
        guard url.isFileURL, PendingAccountRemoval.validPathComponent(accountID) else { throw AccountRemovalError.invalidRecord }
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { return }
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AccountRemovalError.invalidRecord }
        let calendar = try await Task.detached(priority: .utility) { try CalendarStore.open(at: url) }.value
        try await calendar.deleteAccountData(accountID: accountID)
    }

    private func serialized<Value: Sendable>(
        _ action: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        let previous = operation
        let task = Task {
            await previous?.value
            return try await action()
        }
        operation = Task { _ = try? await task.value }
        return try await task.value
    }
}
