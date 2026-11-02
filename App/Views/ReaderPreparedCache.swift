import Foundation
import Diagnostics
import MailStore
import MessageContent
import Observation

/// Invalidation is also observed by retained readers, so old resource handlers
/// disappear immediately when an account or its local cache is removed.
@MainActor @Observable
final class ReaderCacheLifecycle {
    static let shared = ReaderCacheLifecycle()
    private(set) var revision = 0
    private(set) var pressureRevision = 0
    private var pressure: (any DispatchSourceMemoryPressure)?

    private init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { Task { @MainActor in Self.trim() } }
        source.resume()
        pressure = source
    }

    static func invalidate(accountID: String) {
        ReaderPreparedCache.shared.invalidate(accountID: accountID)
        shared.revision &+= 1
    }

    static func reset() {
        ReaderPreparedCache.shared.removeAll()
        shared.revision &+= 1
    }

    static func trim() {
        ReaderPreparedCache.shared.removeAll()
        shared.pressureRevision &+= 1
    }
}

struct ReaderBodyVersion: Hashable, Sendable {
    let fetchedAt: Date
    let htmlBytes: Int
    let textBytes: Int

    init(_ body: MessageBodyRecord) {
        fetchedAt = body.fetchedAt
        htmlBytes = body.html?.utf8.count ?? 0
        textBytes = body.plainText?.utf8.count ?? 0
    }
}

struct ReaderPreparationKey: Hashable, Sendable {
    let accountID: String
    let owner: ObjectIdentifier
    let messageID: String
    let body: ReaderBodyVersion
    let resourcesRevision: Int
    let allowsImages: Bool
    let textOnly: Bool
    let textScale: Double
    let rendererVersion = 1
}

struct PreparedReaderDocument: Sendable {
    let rendered: RenderedMessage?
    let resources: InlineResourceMap
    let searchableText: String

    var byteCount: Int {
        (rendered?.html.utf8.count ?? 0) + searchableText.utf8.count
            + resources.resources.values.reduce(0) { $0 + $1.data.count }
    }
}

/// A serial actor is one bounded CPU lane. Foreground preparation never
/// queues behind speculative work for unrelated messages.
actor ReaderPreparationLane {
    func searchableText(_ body: MessageBodyRecord) throws -> String {
        try Task.checkCancellation()
        let text = MessageDocument.searchableText(ExtractedBody(html: body.html, plainText: body.plainText))
        try Task.checkCancellation()
        return text
    }

    func prepare(body: MessageBodyRecord, records: [MIMEInlineResourceRecord],
                 allowsImages: Bool, textOnly: Bool, textScale: Double) throws -> PreparedReaderDocument {
        try Task.checkCancellation()
        let token = TernSignposts.begin(.readerPreparation)
        var completed = false
        defer { if completed { TernSignposts.end(token) } else { TernSignposts.cancel(token) } }
        let resources = InlineResourceMap(resources: records.map {
            InlineMIMEResource(contentID: $0.contentID, partID: $0.partID, mimeType: $0.mimeType, data: $0.data)
        })
        let extracted = ExtractedBody(html: body.html, plainText: body.plainText)
        let policy = MessageRenderPolicy(allowsRemoteImages: allowsImages, inlineResources: resources, textScale: textScale)
        let rendered = textOnly ? MessageDocument.renderText(extracted) : MessageDocument.render(extracted, policy: policy)
        try Task.checkCancellation()
        // Use all visible text, including long messages beyond the mail index's
        // 100,000-character limit. WebKit remains the authority for each match.
        let text = rendered?.searchableText ?? body.plainText ?? ""
        try Task.checkCancellation()
        completed = true
        return PreparedReaderDocument(rendered: rendered, resources: resources, searchableText: text)
    }
}

/// Shared across windows; bytes include the capability's inline images.
@MainActor
final class ReaderPreparedCache {
    static let shared = ReaderPreparedCache()
    let byteLimit: Int
    private(set) var byteCount = 0
    private(set) var preparationCount = 0
    private var clock: UInt64 = 0
    private var epoch = 0
    private struct MessageIdentity: Hashable { let accountID: String; let messageID: String }
    private struct Revision: Sendable, Equatable { let epoch: Int; let account: Int; let message: Int }
    private var accountRevisions: [String: Int] = [:]
    private var messageRevisions: [MessageIdentity: Int] = [:]
    private let foreground: ReaderPreparationLane
    private let speculative: ReaderPreparationLane
    private struct Entry { let value: PreparedReaderDocument; var used: UInt64 }
    private struct Pending: Sendable {
        let id: UUID
        let task: Task<PreparedReaderDocument, any Error>
        let revision: Revision
        let isSpeculative: Bool
        var waiters: Set<UUID>
    }
    private var entries: [ReaderPreparationKey: Entry] = [:]
    private var pending: [ReaderPreparationKey: Pending] = [:]

    // Eight MiB of the aggregate 64 MiB preparation budget belongs to
    // calendar extraction, which shares the source email content.
    init(byteLimit: Int = 56 * 1_024 * 1_024, foreground: ReaderPreparationLane = ReaderPreparationLane(),
         speculative: ReaderPreparationLane = ReaderPreparationLane()) {
        self.byteLimit = max(0, byteLimit)
        self.foreground = foreground; self.speculative = speculative
    }

    func searchableText(_ body: MessageBodyRecord) async throws -> String {
        try await speculative.searchableText(body)
    }

    func value(for key: ReaderPreparationKey) -> PreparedReaderDocument? {
        guard var entry = entries[key] else { return nil }
        NavigationPerformance.shared.increment(.preparedCacheHit)
        clock &+= 1; entry.used = clock; entries[key] = entry
        return entry.value
    }

    func prepare(key: ReaderPreparationKey, body: MessageBodyRecord, resources: [MIMEInlineResourceRecord],
                 isSpeculative: Bool = false) async throws -> PreparedReaderDocument {
        try Task.checkCancellation()
        if let value = value(for: key) { return value }
        // A selected document must not wait behind unrelated speculative
        // parsing or Find indexing. Cancellation is checked between stages;
        // the replacement always runs on the foreground lane.
        if !isSpeculative, pending[key]?.isSpeculative == true {
            pending.removeValue(forKey: key)?.task.cancel()
        }
        let waiter = UUID()
        let work: Pending
        if var existing = pending[key] {
            existing.waiters.insert(waiter)
            pending[key] = existing
            work = existing
        } else {
            let currentRevision = revision(for: key)
            let id = UUID()
            let lane = isSpeculative ? speculative : foreground
            let task = Task(priority: isSpeculative ? .utility : .userInitiated) { [weak self] in
                var completed = false
                defer { if !completed { NavigationPerformance.shared.increment(.renderCancelled) } }
                let value = try await lane.prepare(body: body, records: resources, allowsImages: key.allowsImages,
                                                  textOnly: key.textOnly, textScale: key.textScale)
                try Task.checkCancellation()
                guard let self, self.revision(for: key) == currentRevision, self.pending[key]?.id == id else { throw CancellationError() }
                self.insert(value, for: key)
                completed = true
                return value
            }
            work = Pending(id: id, task: task, revision: currentRevision, isSpeculative: isSpeculative, waiters: [waiter])
            pending[key] = work
            preparationCount += 1
            NavigationPerformance.shared.increment(.preparedCacheMiss)
            NavigationPerformance.shared.increment(.renderStarted)
        }
        defer { release(key: key, id: work.id, waiter: waiter) }
        let result = try await withTaskCancellationHandler {
            try await work.task.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.release(key: key, id: work.id, waiter: waiter) }
        }
        try Task.checkCancellation()
        guard revision(for: key) == work.revision, pending[key]?.id == work.id else { throw CancellationError() }
        return result
    }

    private func release(key: ReaderPreparationKey, id: UUID, waiter: UUID) {
        guard var work = pending[key], work.id == id else { return }
        work.waiters.remove(waiter)
        if work.waiters.isEmpty {
            pending[key] = nil
            work.task.cancel()
        } else { pending[key] = work }
    }

    func waiterCount(for key: ReaderPreparationKey) -> Int { pending[key]?.waiters.count ?? 0 }

    private func revision(for key: ReaderPreparationKey) -> Revision {
        Revision(epoch: epoch, account: accountRevisions[key.accountID] ?? 0,
                 message: messageRevisions[MessageIdentity(accountID: key.accountID, messageID: key.messageID)] ?? 0)
    }

    func insert(_ value: PreparedReaderDocument, for key: ReaderPreparationKey) {
        if let old = entries.removeValue(forKey: key) { byteCount -= old.value.byteCount }
        guard value.byteCount <= byteLimit else { return }
        while byteCount + value.byteCount > byteLimit, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            if let removed = entries.removeValue(forKey: oldest) { byteCount -= removed.value.byteCount }
        }
        clock &+= 1
        entries[key] = Entry(value: value, used: clock)
        byteCount += value.byteCount
    }

    func invalidate(accountID: String, messageID: String? = nil) {
        if let messageID { messageRevisions[MessageIdentity(accountID: accountID, messageID: messageID), default: 0] &+= 1 }
        else { accountRevisions[accountID, default: 0] &+= 1 }
        func matches(_ key: ReaderPreparationKey) -> Bool {
            key.accountID == accountID && (messageID == nil || key.messageID == messageID)
        }
        for key in Array(entries.keys) where matches(key) {
            if let removed = entries.removeValue(forKey: key) { byteCount -= removed.value.byteCount }
        }
        for key in Array(pending.keys) where matches(key) { pending.removeValue(forKey: key)?.task.cancel() }
    }

    func removeAll() {
        for work in pending.values { work.task.cancel() }
        pending.removeAll(); entries.removeAll(); byteCount = 0; epoch &+= 1
        accountRevisions.removeAll(); messageRevisions.removeAll()
    }
}
