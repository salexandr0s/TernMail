import Foundation
import Synchronization
import TernAI

struct AssistantStoredWritingStyle: Codable, Equatable, Sendable {
    let accountID: String
    let email: String
    let revision: UUID
    let profile: WritingStyleProfile
    let hasLimitedCoverage: Bool

    func validate() throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 512,
              !email.isEmpty, email.utf8.count <= 512 else { throw AssistantWritingStyleStoreError.invalidData }
        try profile.validate()
    }
}

struct AssistantWritingStyleArchive: Codable, Equatable, Sendable {
    var version = 1
    var profiles: [AssistantStoredWritingStyle] = []
    var disabledAccountIDs: Set<String> = []

    func validate() throws {
        guard version == 1, profiles.count <= 100, disabledAccountIDs.count <= 100,
              Set(profiles.map(\.accountID)).count == profiles.count,
              disabledAccountIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else {
            throw AssistantWritingStyleStoreError.invalidData
        }
        for profile in profiles { try profile.validate() }
    }
}

/// A write of the profile file that has been queued. Its value arrives once the
/// file is written, and it throws if the write failed.
typealias AssistantWritingStyleWrite = Task<Void, any Error>

@MainActor
protocol AssistantWritingStyleStore {
    var disabledAccountIDs: Set<String> { get }
    func setDisabledAccountIDs(_ ids: Set<String>) throws
    /// The saved archive, including every write queued before this call.
    func load() throws -> AssistantWritingStyleArchive
    /// Saves the opt-outs before returning, then queues the profile file behind
    /// earlier writes, so writes land in the order they were made.
    func save(_ archive: AssistantWritingStyleArchive) throws -> AssistantWritingStyleWrite
}

@MainActor
final class MemoryAssistantWritingStyleStore: AssistantWritingStyleStore {
    private var archive: AssistantWritingStyleArchive
    init(archive: AssistantWritingStyleArchive = .init()) { self.archive = archive }
    var disabledAccountIDs: Set<String> { archive.disabledAccountIDs }
    func setDisabledAccountIDs(_ ids: Set<String>) throws { archive.disabledAccountIDs = ids }
    func load() throws -> AssistantWritingStyleArchive { try archive.validate(); return archive }
    func save(_ archive: AssistantWritingStyleArchive) throws -> AssistantWritingStyleWrite {
        try archive.validate()
        self.archive = archive
        return Task {}
    }
}

/// One archive file. Its reads and writes run one at a time on a background queue,
/// in the order they were queued, so no write lands before an earlier one.
final class AssistantWritingStyleFile: Sendable {
    static let maximumBytes = 512_000
    let url: URL?
    private let queue = DispatchQueue(label: "dev.tern.writing-styles", qos: .utility)
    /// What `preload` read. A write clears it, so it is never older than the file.
    private let preloaded = Mutex<AssistantWritingStyleArchive?>(nil)

    init(url: URL?) { self.url = url }

    /// Reads the file in the background and keeps the result for the next `read`.
    func preload() {
        guard let url else { return }
        queue.async {
            let archive = try? Self.contents(of: url)
            self.preloaded.withLock { $0 = archive }
        }
    }

    /// The saved archive: the preloaded one when nothing was written after it, and
    /// otherwise the file, read before this returns. Both wait for queued work
    /// first, so the result includes every earlier write.
    func read() throws -> AssistantWritingStyleArchive {
        guard let url else { throw AssistantWritingStyleStoreError.unavailable }
        return try queue.sync {
            try preloaded.withLock { $0 } ?? Self.contents(of: url)
        }
    }

    /// Queues a write behind the work already queued.
    func write(_ archive: AssistantWritingStyleArchive) -> AssistantWritingStyleWrite {
        let (results, continuation) = AsyncThrowingStream<Void, any Error>.makeStream()
        queue.async {
            self.preloaded.withLock { $0 = nil }
            continuation.yield(with: Result { try self.replaceContents(with: archive) })
            continuation.finish()
        }
        // The stream carries the one result from the queue to whoever awaits the write.
        return Task { for try await _ in results {} }
    }

    private static func contents(of url: URL) throws -> AssistantWritingStyleArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
            throw AssistantWritingStyleStoreError.invalidData
        }
        let data = try Data(contentsOf: url)
        guard data.count <= maximumBytes else { throw AssistantWritingStyleStoreError.invalidData }
        return try JSONDecoder().decode(AssistantWritingStyleArchive.self, from: data)
    }

    private func replaceContents(with archive: AssistantWritingStyleArchive) throws {
        guard let url else { throw AssistantWritingStyleStoreError.unavailable }
        let data = try JSONEncoder().encode(archive)
        guard data.count <= Self.maximumBytes else { throw AssistantWritingStyleStoreError.invalidData }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
struct FileAssistantWritingStyleStore: AssistantWritingStyleStore {
    let file: AssistantWritingStyleFile
    var preferences: UserDefaults?
    private static let disabledKey = "assistant.writingStyle.disabledAccounts"

    init(file: AssistantWritingStyleFile, preferences: UserDefaults? = nil) {
        self.file = file
        self.preferences = preferences
    }

    init(url: URL?, preferences: UserDefaults? = nil) {
        self.init(file: AssistantWritingStyleFile(url: url), preferences: preferences)
    }

    var disabledAccountIDs: Set<String> { Set(preferences?.stringArray(forKey: Self.disabledKey) ?? []) }
    func setDisabledAccountIDs(_ ids: Set<String>) throws {
        preferences?.set(ids.sorted(), forKey: Self.disabledKey)
    }

    /// The opt-outs are read here rather than with the file, so one saved after a
    /// preload still applies to what the preload read.
    func load() throws -> AssistantWritingStyleArchive {
        var archive = try file.read()
        archive.disabledAccountIDs.formUnion(disabledAccountIDs)
        try archive.validate()
        return archive
    }

    func save(_ archive: AssistantWritingStyleArchive) throws -> AssistantWritingStyleWrite {
        try archive.validate()
        // Persist opt-outs first, so a failed or unfinished profile-file rewrite cannot
        // enable learning again at the next launch. This contains only account IDs.
        try setDisabledAccountIDs(archive.disabledAccountIDs)
        guard file.url != nil else { throw AssistantWritingStyleStoreError.unavailable }
        return file.write(archive)
    }
}

enum AssistantWritingStyleStoreError: Error, LocalizedError {
    case invalidData, unavailable
    var errorDescription: String? {
        switch self {
        case .invalidData: "The saved writing styles could not be read. Learn them again from sent mail."
        case .unavailable: "Tern could not save writing styles on this Mac."
        }
    }
}

@MainActor
enum AssistantWritingStyleStores {
    /// Every default store shares this file, so the assistant and account removal
    /// queue their writes in one order.
    private static let file: AssistantWritingStyleFile = {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return AssistantWritingStyleFile(url: root?.appending(path: "Tern/WritingStyles.json"))
    }()

    static func makeDefault() -> any AssistantWritingStyleStore {
        if LaunchMode.current.isIsolated {
            return MemoryAssistantWritingStyleStore()
        }
        return FileAssistantWritingStyleStore(file: file, preferences: .standard)
    }

    /// Starts reading the saved styles in the background. Called once at launch, it
    /// lets the assistant's first use find them in memory instead of reading the
    /// file on the main actor.
    static func preload() {
        if !LaunchMode.current.isIsolated { file.preload() }
    }
}
