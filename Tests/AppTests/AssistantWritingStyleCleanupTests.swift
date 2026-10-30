import Foundation
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct AssistantWritingStyleCleanupTests {
    @Test func removalWithoutAssistantErasesOnlyThatAccountsProfile() throws {
        let profile = try WritingStyleProfile(sampleCount: 5, profiledAt: .now,
            traits: .init(formality: .informal, detail: .brief))
        let store = MemoryAssistantWritingStyleStore(archive: .init(profiles: ["a", "b"].map {
            AssistantStoredWritingStyle(accountID: $0, email: "\($0)@example.invalid",
                revision: UUID(), profile: profile, hasLimitedCoverage: false)
        }))

        try AssistantWritingStyleCleanup.remove(accountID: "a", store: store)

        let saved = try store.load()
        #expect(saved.profiles.map(\.accountID) == ["b"])
        #expect(saved.disabledAccountIDs.contains("a"))
        #expect(!saved.disabledAccountIDs.contains("b"))
    }

    @Test func unreadableProfileFileStillRecordsRemovalOptOut() throws {
        let suite = "WritingStyleCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "styles.json")
        let invalid = Data("not a profile archive".utf8)
        try invalid.write(to: url)
        let store = FileAssistantWritingStyleStore(url: url, preferences: defaults)

        #expect(throws: (any Error).self) {
            try AssistantWritingStyleCleanup.remove(accountID: "a", store: store)
        }

        #expect(store.disabledAccountIDs.contains("a"))
        #expect(try Data(contentsOf: url) == invalid)
    }
}
