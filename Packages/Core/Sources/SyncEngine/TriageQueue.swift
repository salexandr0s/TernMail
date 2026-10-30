import Foundation
import GmailAPI
import MailStore

/// IDs are always interpreted in this engine's account.
public enum MailActionTarget: Sendable, Equatable {
    case threads([String])
    case messages([String])
}

public enum TriageAction: Sendable {
    case spam, notSpam, important, notImportant
}

public enum TriageError: Error, Sendable, Equatable {
    case unavailable
    case permissionRequired
    case invalidDeletionScope
    case accountMismatch
    case incompleteResponse
}

/// A counted snapshot. Only a preparation operation can construct one.
public struct PermanentDeletionApproval: Sendable, Equatable, Identifiable {
    public let id = UUID()
    public let accountID: String
    public let labelID: String
    public let messageIDs: [String]
    public let preparedAt: Date
    public var count: Int { messageIDs.count }
}

extension SyncEngine {
    public func rawMessage(id: String) async throws -> Data {
        guard !isStopped, let triage else { throw TriageError.unavailable }
        return try await triage.rawMessage(id: id)
    }

    @discardableResult
    public func perform(_ action: MailAction, target: MailActionTarget) async throws -> ActionReceipt? {
        if case .threads(let ids) = target { return try await perform(action, threadIDs: ids) }
        let add: [String]
        let remove: [String]
        switch action {
        case .archive: add = []; remove = [SystemLabel.inbox]
        case .trash: return try await queueMessageChanges(target, kind: .trashMessages, add: [SystemLabel.trash], remove: [SystemLabel.inbox])
        case .markRead: add = []; remove = [SystemLabel.unread]
        case .markUnread: add = [SystemLabel.unread]; remove = []
        case .star: add = [SystemLabel.starred]; remove = []
        case .unstar: add = []; remove = [SystemLabel.starred]
        }
        return try await queueMessageChanges(target, add: add, remove: remove)
    }

    @discardableResult
    public func performTriage(_ action: TriageAction, target: MailActionTarget) async throws -> ActionReceipt? {
        switch action {
        case .spam: try await editLabels(target: target, add: [SystemLabel.spam], remove: [SystemLabel.inbox])
        case .notSpam: try await editLabels(target: target, add: [SystemLabel.inbox], remove: [SystemLabel.spam])
        case .important: try await editLabels(target: target, add: [SystemLabel.important], remove: [])
        case .notImportant: try await editLabels(target: target, add: [], remove: [SystemLabel.important])
        }
    }

    @discardableResult
    public func editLabels(target: MailActionTarget, add: [String], remove: [String]) async throws -> ActionReceipt? {
        switch target {
        case .threads(let ids): try await editLabels(threadIDs: ids, add: add, remove: remove)
        case .messages: try await queueMessageChanges(target, add: add, remove: remove)
        }
    }

    @discardableResult
    public func move(target: MailActionTarget, to labelID: String, from mailboxLabelID: String) async throws -> ActionReceipt? {
        if case .threads(let ids) = target { return try await move(threadIDs: ids, to: labelID, from: mailboxLabelID) }
        let accountID = accountID
        let source = try await cache.read { tx in
            let id = try tx.resolvedLabelID(mailboxLabelID, accountID: accountID)
            let user = try tx.displayedLabels(accountID: accountID).contains { $0.id == id && !$0.isSystem }
            return id == SystemLabel.inbox || user ? id : SystemLabel.inbox
        }
        return try await queueMessageChanges(target, add: [labelID], remove: [source])
    }

    private func queueMessageChanges(
        _ target: MailActionTarget, kind: PendingAction.Kind = .modifyMessages, add: [String], remove: [String]
    ) async throws -> ActionReceipt? {
        guard case .messages(let requested) = target else { return nil }
        let ids = Array(Set(requested)).sorted()
        guard !ids.isEmpty else { return nil }
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(undoHold)
        let rows = try await write { tx in
            let add = try add.map { try tx.resolvedLabelID($0, accountID: accountID) }
            let remove = try remove.map { try tx.resolvedLabelID($0, accountID: accountID) }.filter { !add.contains($0) }
            return try stride(from: 0, to: ids.count, by: 1000).map { start in
                try tx.enqueue(kind, accountID: accountID, messageIDs: Array(ids[start..<min(start + 1000, ids.count)]),
                    add: add, remove: remove, now: now, notBefore: notBefore)
            }
        }
        scheduleSending()
        return register(rows)
    }

    public func setLabelVisibility(_ labelID: String, to visibility: LabelListVisibility) async throws -> ActionReceipt? {
        guard triage != nil else { throw TriageError.unavailable }
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(undoHold)
        let row = try await write { tx -> PendingAction? in
            guard let label = try tx.displayedLabels(accountID: accountID).first(where: { $0.id == labelID }), !label.isSystem else {
                throw LabelChangeError.notAUserLabel
            }
            let old = label.labelListVisibility.flatMap(LabelListVisibility.init(rawValue:)) ?? .show
            guard old != visibility else { return nil }
            return try tx.enqueueLabelChange(.updateLabel, labelID: labelID,
                change: .init(newVisibility: visibility, oldVisibility: old),
                accountID: accountID, now: now, notBefore: notBefore)
        }
        guard let row else { return nil }
        scheduleSending()
        return register([row])
    }

    /// Capture unread IDs from Google, then retain their individual Undo diffs.
    public func markAllRead(labelID: String) async throws -> ActionReceipt? {
        let listed = try await listAllMessageIDs(labelID: labelID, query: "is:unread")
        let messages = try await currentMessages(ids: listed)
        let ids = messages.filter { $0.labelIds?.contains(SystemLabel.unread) == true }.map(\.id).sorted()
        guard !ids.isEmpty else { return nil }
        let accountID = accountID
        let now = now()
        let notBefore = now.addingTimeInterval(undoHold)
        let rows = try await write { tx in
            try stride(from: 0, to: ids.count, by: 1000).map { start in
                let chunk = Array(ids[start..<min(start + 1000, ids.count)])
                var row = try tx.enqueue(.modifyMessages, accountID: accountID, messageIDs: chunk,
                    remove: [SystemLabel.unread], now: now, notBefore: notBefore)
                row.diff = Dictionary(uniqueKeysWithValues: chunk.map { ($0, .init(added: [], removed: [SystemLabel.unread])) })
                try tx.updateAction(row)
                return row
            }
        }
        scheduleSending()
        return register(rows)
    }

    public func preparePermanentDeletion(labelID: String, target: MailActionTarget? = nil) async throws -> PermanentDeletionApproval {
        guard [SystemLabel.spam, SystemLabel.trash].contains(labelID) else { throw TriageError.invalidDeletionScope }
        guard triage != nil, !isStopped else { throw TriageError.unavailable }
        let ids: [String]
        switch target {
        case .messages(let selected): ids = Array(Set(selected)).sorted()
        case .threads(let selected):
            var found = Set<String>()
            for threadID in Set(selected).sorted() {
                let thread = try await gmail.thread(id: threadID, format: .minimal)
                guard thread.id == threadID, let messages = thread.messages,
                      messages.allSatisfy({ $0.threadId == threadID }) else { throw TriageError.incompleteResponse }
                found.formUnion(messages.map(\.id))
            }
            ids = found.sorted()
        case nil: ids = try await listAllMessageIDs(labelID: labelID, query: nil)
        }
        let messages = try await currentMessages(ids: ids)
        let eligible = messages.filter { $0.labelIds?.contains(labelID) == true }.map(\.id).sorted()
        return PermanentDeletionApproval(accountID: accountID, labelID: labelID, messageIDs: eligible, preparedAt: now())
    }

    /// Call only after the user approves the displayed immutable count/IDs.
    public func deletePermanently(approved: PermanentDeletionApproval) async throws {
        guard approved.accountID == accountID else { throw TriageError.accountMismatch }
        guard [SystemLabel.spam, SystemLabel.trash].contains(approved.labelID) else { throw TriageError.invalidDeletionScope }
        try await requirePermanentDeletionPermission()
        guard !approved.messageIDs.isEmpty else { return }
        let accountID = accountID
        let now = now()
        let ids = approved.messageIDs
        _ = try await write { tx in
            try stride(from: 0, to: ids.count, by: 1000).map { start in
                var row = try tx.enqueue(.deleteMessages, accountID: accountID,
                    messageIDs: Array(ids[start..<min(start + 1000, ids.count)]), now: now, notBefore: now)
                row.labelID = approved.labelID
                try tx.updateAction(row)
                return row
            }
        }
        scheduleSending()
    }

    func deliverPermanentDeletion(_ row: PendingAction) async throws {
        guard let triage, let labelID = row.labelID, [SystemLabel.spam, SystemLabel.trash].contains(labelID) else {
            throw GmailError.invalidRequest("Invalid permanent deletion scope")
        }
        try await requirePermanentDeletionPermission()
        let messages = try await currentMessages(ids: row.messageIDs)
        let valid = messages.filter { $0.labelIds?.contains(labelID) == true }.map(\.id)
        let gone = Set(row.messageIDs).subtracting(messages.map(\.id))
        try await requirePermanentDeletionPermission()
        try Task.checkCancellation()
        guard !isStopped else { throw CancellationError() }
        try await triage.batchDeleteMessages(ids: valid)
        let removed = gone.union(valid)
        let accountID = accountID
        deletedMessageIDs.withLock { $0.formUnion(removed) }
        try await write { tx in
            let threads = try tx.deleteMessages(ids: removed, accountID: accountID)
            try tx.rebuildThreads(threads, accountID: accountID)
        }
    }

    private func requirePermanentDeletionPermission() async throws {
        guard let accounts, let record = try await accounts.accounts().first(where: { $0.id == accountID }),
              record.enabledFeatures.contains(AccountFeature.permanentDeletion.rawValue),
              GoogleScopes.isCovered(.permanentDeletion, by: record.grantedScopes) else {
            throw GmailError.http(status: 403, reason: "ACCESS_TOKEN_SCOPE_INSUFFICIENT")
        }
    }

    private func listAllMessageIDs(labelID: String, query: String?) async throws -> [String] {
        guard !labelID.hasPrefix("TERN_") || labelID == SystemLabel.allMail else { throw TriageError.unavailable }
        var ids = Set<String>()
        var next: String?
        var tokens = Set<String>()
        repeat {
            try Task.checkCancellation()
            guard !isStopped else { throw CancellationError() }
            let page = try await gmail.listMessages(query: query, labelIDs: labelID == SystemLabel.allMail ? [] : [labelID],
                includeSpamTrash: [SystemLabel.spam, SystemLabel.trash].contains(labelID), pageToken: next, maxResults: 500)
            ids.formUnion(page.messages?.map(\.id) ?? [])
            next = page.nextPageToken
            if let next, !tokens.insert(next).inserted { throw TriageError.incompleteResponse }
        } while next != nil
        return ids.sorted()
    }

    private func currentMessages(ids: [String]) async throws -> [GmailMessage] {
        guard !ids.isEmpty else { return [] }
        var found: [GmailMessage] = []
        for start in stride(from: 0, to: ids.count, by: 1000) {
            try Task.checkCancellation()
            guard !isStopped else { throw CancellationError() }
            let chunk = Array(ids[start..<min(start + 1000, ids.count)])
            let result = try await gmail.messages(ids: chunk, format: .minimal, metadataHeaders: [])
            for id in chunk {
                guard let message = result[id] else { throw TriageError.incompleteResponse }
                switch message {
                case .success(let value):
                    guard value.id == id else { throw TriageError.incompleteResponse }
                    found.append(value)
                case .failure(.notFound): continue
                case .failure(let error): throw error
                }
            }
        }
        return found
    }
}
