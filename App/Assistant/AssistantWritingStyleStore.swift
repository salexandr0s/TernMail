import Foundation
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

@MainActor
protocol AssistantWritingStyleStore {
    var disabledAccountIDs: Set<String> { get }
    func setDisabledAccountIDs(_ ids: Set<String>) throws
    func load() throws -> AssistantWritingStyleArchive
    func save(_ archive: AssistantWritingStyleArchive) throws
}

@MainActor
final class MemoryAssistantWritingStyleStore: AssistantWritingStyleStore {
    private var archive: AssistantWritingStyleArchive
    init(archive: AssistantWritingStyleArchive = .init()) { self.archive = archive }
    var disabledAccountIDs: Set<String> { archive.disabledAccountIDs }
    func setDisabledAccountIDs(_ ids: Set<String>) throws { archive.disabledAccountIDs = ids }
    func load() throws -> AssistantWritingStyleArchive { try archive.validate(); return archive }
    func save(_ archive: AssistantWritingStyleArchive) throws { try archive.validate(); self.archive = archive }
}

@MainActor
struct FileAssistantWritingStyleStore: AssistantWritingStyleStore {
    let url: URL?
    var preferences: UserDefaults? = nil
    static let maximumBytes = 512_000
    private static let disabledKey = "assistant.writingStyle.disabledAccounts"
    var disabledAccountIDs: Set<String> { Set(preferences?.stringArray(forKey: Self.disabledKey) ?? []) }
    func setDisabledAccountIDs(_ ids: Set<String>) throws {
        preferences?.set(ids.sorted(), forKey: Self.disabledKey)
    }

    func load() throws -> AssistantWritingStyleArchive {
        guard let url else { throw AssistantWritingStyleStoreError.unavailable }
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes else {
            throw AssistantWritingStyleStoreError.invalidData
        }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maximumBytes else { throw AssistantWritingStyleStoreError.invalidData }
        var archive = try JSONDecoder().decode(AssistantWritingStyleArchive.self, from: data)
        archive.disabledAccountIDs.formUnion(disabledAccountIDs)
        try archive.validate()
        return archive
    }

    func save(_ archive: AssistantWritingStyleArchive) throws {
        try archive.validate()
        // Persist opt-outs first, so a failed profile-file rewrite cannot enable
        // learning again at the next launch. This contains only account IDs.
        try setDisabledAccountIDs(archive.disabledAccountIDs)
        guard let url else { throw AssistantWritingStyleStoreError.unavailable }
        let data = try JSONEncoder().encode(archive)
        guard data.count <= Self.maximumBytes else { throw AssistantWritingStyleStoreError.invalidData }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
    static func makeDefault() -> any AssistantWritingStyleStore {
        if AssistantRuntimeEnvironment.isTestHost || ProcessInfo.processInfo.arguments.contains("--ui-audit") {
            return MemoryAssistantWritingStyleStore()
        }
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return FileAssistantWritingStyleStore(url: root?.appending(path: "Tern/WritingStyles.json"), preferences: .standard)
    }
}
