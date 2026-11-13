import Foundation
import Testing
import TernAI
@testable import Tern

@Suite @MainActor struct AssistantWritingStyleCleanupTests {
    @Test func removalWithoutAssistantErasesOnlyThatAccountsProfile() async throws {
        let store = MemoryAssistantWritingStyleStore(archive: try archive(["a", "b"]))

        try await AssistantWritingStyleCleanup.erase(accountID: "a", store: store)

        let saved = try store.load()
        #expect(saved.profiles.map(\.accountID) == ["b"])
        #expect(saved.disabledAccountIDs.contains("a"))
        #expect(!saved.disabledAccountIDs.contains("b"))
    }

    @Test func unreadableProfileFileStillRecordsRemovalOptOut() async throws {
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

        await #expect(throws: (any Error).self) {
            try await AssistantWritingStyleCleanup.erase(accountID: "a", store: store)
        }

        #expect(store.disabledAccountIDs.contains("a"))
        #expect(try Data(contentsOf: url) == invalid)
    }

    @Test func removalIsInTheFileWhenItReturnsAndLandsBehindEarlierSaves() async throws {
        let suite = "WritingStyleCleanupTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "styles.json")
        let store = FileAssistantWritingStyleStore(url: url, preferences: defaults)
        // Queued and not awaited: the removal must not be overwritten by it.
        let earlier = try store.save(try archive(["a", "b"]))

        try await AssistantWritingStyleCleanup.erase(accountID: "a", store: store)

        // The file itself is all that a quit right after `erase` leaves behind.
        let saved = try JSONDecoder().decode(AssistantWritingStyleArchive.self, from: Data(contentsOf: url))
        #expect(saved.profiles.map(\.accountID) == ["b"])
        #expect(saved.disabledAccountIDs == ["a"])
        #expect(store.disabledAccountIDs == ["a"])
        try await earlier.value
    }

    private func archive(_ accountIDs: [String]) throws -> AssistantWritingStyleArchive {
        let profile = try WritingStyleProfile(sampleCount: 5, profiledAt: .now,
            traits: .init(formality: .informal, detail: .brief))
        return .init(profiles: accountIDs.map {
            AssistantStoredWritingStyle(accountID: $0, email: "\($0)@example.invalid",
                revision: UUID(), profile: profile, hasLimitedCoverage: false)
        })
    }
}
