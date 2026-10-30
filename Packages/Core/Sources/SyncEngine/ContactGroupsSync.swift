import Foundation
import GmailAPI
import MailStore
import MessageContent

public protocol ContactGroupService: Sendable {
    func contactGroups() async throws -> ContactGroupCatalog
    func contactGroup(resourceName: String) async throws -> GoogleContactGroup
    func contactGroupPeople(resourceNames: [String]) async throws -> ContactGroupPeople
}

extension PeopleClient: ContactGroupService {}

public enum ContactGroupError: Error, Sendable, Equatable { case unavailable, missing }

extension SyncEngine {
    public func syncContactGroups() async throws {
        guard let service = people as? any ContactGroupService else { return }
        guard try await contactsAreOn() else { return }
        try await checkContactEnrichmentAccess()
        let accountID = accountID
        guard let generation = try await cache.read({ try $0.contactEnrichmentGeneration(accountID: accountID) }) else { return }
        let catalog = try await service.contactGroups()
        try await checkContactEnrichmentAccess()
        let timestamp = now()
        try await write { tx in
            guard try tx.contactEnrichmentGeneration(accountID: accountID) == generation else { throw CancellationError() }
            try tx.replaceContactGroups(catalog, accountID: accountID, at: timestamp)
        }
        if try await !contactsAreOn() { try await write { try $0.deleteContacts(accountID: accountID) } }
    }

    /// Selection resolves fresh membership and every member address. An incomplete result is never permission to insert a subset.
    public func expandContactGroup(_ suggestion: ContactGroupSuggestion) async throws -> ContactGroupExpansion {
        guard suggestion.accountID == accountID, let service = people as? any ContactGroupService else { throw ContactGroupError.unavailable }
        try await checkContactEnrichmentAccess()
        let accountID = accountID
        guard let generation = try await cache.read({ try $0.contactEnrichmentGeneration(accountID: accountID) }) else { throw ContactGroupError.unavailable }
        let group = try await service.contactGroup(resourceName: suggestion.resourceName)
        try await checkContactEnrichmentAccess()
        guard group.resourceName == suggestion.resourceName, group.isUserGroup else { throw ContactGroupError.missing }
        let memberIDs = group.memberResourceNames ?? []
        let count = group.memberCount ?? -1
        let complete = count >= 0 && count == memberIDs.count && Set(memberIDs).count == count && count <= PeopleClient.maximumGroupMembers
        let current = ContactGroupSuggestion(accountID: accountID, resourceName: group.resourceName, name: group.name ?? suggestion.name,
            memberCount: max(0, count), isComplete: complete, fetchedAt: now())
        guard complete else { return ContactGroupExpansion(group: current, recipients: [], didTruncate: true) }
        let fetched = try await service.contactGroupPeople(resourceNames: memberIDs)
        try await checkContactEnrichmentAccess()
        guard try await cache.read({ try $0.contactEnrichmentGeneration(accountID: accountID) }) == generation else { throw CancellationError() }
        var missing = Set(fetched.missingResourceNames)
        var recipients: [EmailAddress] = []
        var seen = Set<String>()
        var invalid = 0
        var truncated = false
        for memberID in memberIDs {
            guard let person = fetched.peopleByResourceName[memberID], !person.isDeleted else { missing.insert(memberID); continue }
            if person.addresses.isEmpty { missing.insert(memberID) }
            for value in person.addresses {
                let address = EmailAddress(name: person.displayName, address: value)
                guard address.isValid else { invalid += 1; continue }
                guard seen.insert(address.normalized).inserted else { continue }
                if recipients.count >= PeopleClient.maximumGroupMembers { truncated = true; continue }
                recipients.append(address)
            }
        }
        return ContactGroupExpansion(group: current, recipients: recipients, missingMemberResourceNames: missing.sorted(),
            invalidAddressCount: invalid, didTruncate: truncated)
    }

    func checkContactEnrichmentAccess() async throws {
        try Task.checkCancellation()
        guard !isStopped, !stopRequested.withLock({ $0 }), try await contactsAreOn() else { throw ContactGroupError.unavailable }
    }
}
