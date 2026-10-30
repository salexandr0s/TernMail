import Foundation
@testable import GmailAPI
import MailStore
import MessageContent
import Testing
@testable import SyncEngine

@Suite struct ContactGroupExpansionTests {
    @Test func expansionKeepsEveryValidAddressAndReportsUnresolvedMembers() async throws {
        let (engine, _, _, people) = try await setup()
        let group = ContactGroupSuggestion(accountID: "a", resourceName: "contactGroups/team", name: "Team", memberCount: 2)
        let full = try await engine.expandContactGroup(group)
        #expect(full.isComplete)
        #expect(full.recipients.map(\.address) == ["one@example.test", "alias@example.test", "two@example.test"])
        await people.setMissing()
        let incomplete = try await engine.expandContactGroup(group)
        #expect(!incomplete.isComplete)
        #expect(incomplete.missingMemberResourceNames == ["people/two"])
        let foreign = ContactGroupSuggestion(accountID: "b", resourceName: group.resourceName, name: group.name, memberCount: 2)
        await #expect(throws: ContactGroupError.self) { try await engine.expandContactGroup(foreign) }
    }

    @Test func offOnDuringMemberFetchInvalidatesTheOldExpansion() async throws {
        let (engine, cache, accounts, people) = try await setup()
        await people.holdNext()
        let pending = Task { try await engine.expandContactGroup(.init(accountID: "a", resourceName: "contactGroups/team", name: "Team", memberCount: 2)) }
        await people.waitUntilHeld()
        try await accounts.updateAccount(id: "a") { $0.enabledFeatures = [] }
        try await cache.write { try $0.deleteContacts(accountID: "a") }
        try await accounts.updateAccount(id: "a") { $0.enabledFeatures = [AccountFeature.contacts.rawValue] }
        try await cache.write { tx in try tx.applyEnrichedContactSync([], source: .connection, syncToken: "new", fields: PeopleClient.fields, isFullSync: true, now: .now, accountID: "a") }
        await people.release()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await cache.contactGroupSuggestions(accountID: "a", matching: "Team").isEmpty)
    }

    private func setup() async throws -> (SyncEngine, MailCache, AccountStore, GroupPeople) {
        let accounts = try AccountStore.inMemory()
        try await accounts.save(.init(id: "a", email: "me@example.test", displayName: nil, grantedScopes: [GoogleScopes.contacts, GoogleScopes.otherContacts],
            addedAt: .now, enabledFeatures: [AccountFeature.contacts.rawValue]))
        let cache = try MailCache.inMemory()
        try await cache.write { tx in try tx.applyEnrichedContactSync([], source: .connection, syncToken: "one", fields: PeopleClient.fields, isFullSync: true, now: .now, accountID: "a") }
        let people = GroupPeople()
        let engine = SyncEngine(accountID: "a", sender: .init(address: "me@example.test"), outgoingDirectory: FileManager.default.temporaryDirectory,
            gmail: FakeGmail(), people: people, accounts: accounts, cache: cache, sendsAutomatically: false)
        return (engine, cache, accounts, people)
    }
}

private actor GroupPeople: PeopleService, ContactGroupService {
    private var missing = false
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    func setMissing() { missing = true }
    func holdNext() { shouldHold = true }
    func waitUntilHeld() async { while held == nil { await Task.yield() } }
    func release() { held?.resume(); held = nil }
    func sync(_ source: PeopleClient.Source, syncToken: String?) async throws -> ContactSync { .init(people: [], syncToken: nil) }
    func contactGroups() async throws -> ContactGroupCatalog { .init(groups: [], isComplete: true) }
    func contactGroup(resourceName: String) async throws -> GoogleContactGroup {
        try JSONDecoder().decode(GoogleContactGroup.self, from: Data(#"{"resourceName":"contactGroups/team","name":"Team","groupType":"USER_CONTACT_GROUP","memberCount":2,"memberResourceNames":["people/one","people/two"]}"#.utf8))
    }
    func contactGroupPeople(resourceNames: [String]) async throws -> ContactGroupPeople {
        if shouldHold { shouldHold = false; await withCheckedContinuation { held = $0 } }
        let one = try JSONDecoder().decode(Person.self, from: Data(#"{"resourceName":"people/one","emailAddresses":[{"value":"one@example.test"},{"value":"alias@example.test"}]}"#.utf8))
        let two = try JSONDecoder().decode(Person.self, from: Data(#"{"resourceName":"people/two","emailAddresses":[{"value":"two@example.test"}]}"#.utf8))
        return .init(peopleByResourceName: missing ? ["people/one": one] : ["people/one": one, "people/two": two], missingResourceNames: missing ? ["people/two"] : [])
    }
}
