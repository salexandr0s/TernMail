import Foundation

extension PeopleClient {
    public static let maximumGroups = 1_000
    public static let maximumGroupMembers = 1_000

    /// The list omits members. Selection fetches the current member set separately.
    public func contactGroups() async throws -> ContactGroupCatalog {
        var groups: [GoogleContactGroup] = []
        var seenGroups = Set<String>()
        var seenPages = Set<String>()
        var pageToken: String?
        for _ in 0..<20 {
            try Task.checkCancellation()
            var query = [URLQueryItem(name: "pageSize", value: "100"),
                URLQueryItem(name: "groupFields", value: "name,groupType,memberCount,metadata")]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            let page: ContactGroupsResponse = try session.decode(await session.send(request(path: "/v1/contactGroups", query: query)).data)
            for group in page.contactGroups ?? [] where group.isUserGroup {
                guard Self.isPeopleResource(group.resourceName, prefix: "contactGroups/") else { throw GmailError.decoding("Contact group identity") }
                if seenGroups.insert(group.resourceName).inserted {
                    guard groups.count < Self.maximumGroups else { return ContactGroupCatalog(groups: groups, isComplete: false) }
                    groups.append(group)
                }
            }
            guard let next = page.nextPageToken, !next.isEmpty else { return ContactGroupCatalog(groups: groups, isComplete: true) }
            guard groups.count < Self.maximumGroups else { return ContactGroupCatalog(groups: groups, isComplete: false) }
            guard seenPages.insert(next).inserted else { throw GmailError.decoding("Contact group pagination") }
            pageToken = next
        }
        return ContactGroupCatalog(groups: groups, isComplete: false)
    }

    public func contactGroup(resourceName: String) async throws -> GoogleContactGroup {
        guard Self.isPeopleResource(resourceName, prefix: "contactGroups/") else { throw GmailError.invalidRequest("Contact group identity") }
        let query = [URLQueryItem(name: "maxMembers", value: String(Self.maximumGroupMembers)),
            URLQueryItem(name: "groupFields", value: "name,groupType,memberCount,metadata")]
        let value: GoogleContactGroup = try session.decode(await session.send(request(path: "/v1/" + resourceName, query: query)).data)
        guard value.resourceName == resourceName else { throw GmailError.decoding("Contact group identity") }
        return value
    }

    /// Bound each batch to Google's 200-resource limit and retain every failed member identity.
    public func contactGroupPeople(resourceNames: [String]) async throws -> ContactGroupPeople {
        let ids = Array(Set(resourceNames)).sorted()
        guard ids.count <= Self.maximumGroupMembers, ids.allSatisfy({ Self.isPeopleResource($0, prefix: "people/") }) else {
            throw GmailError.invalidRequest("Contact group members")
        }
        var people: [String: Person] = [:]
        for start in stride(from: 0, to: ids.count, by: 200) {
            try Task.checkCancellation()
            let chunk = Array(ids[start..<min(start + 200, ids.count)])
            var query = chunk.map { URLQueryItem(name: "resourceNames", value: $0) }
            query += [URLQueryItem(name: "personFields", value: Self.fields), URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_CONTACT")]
            let page: ContactGroupPeopleResponse = try session.decode(await session.send(request(path: "/v1/people:batchGet", query: query)).data)
            var answered = Set<String>()
            for item in page.responses ?? [] {
                guard let id = item.requestedResourceName, chunk.contains(id), answered.insert(id).inserted else {
                    throw GmailError.decoding("Contact group member identity")
                }
                guard (item.status?.code ?? 0) == 0, (item.httpStatusCode ?? 200) == 200,
                      let person = item.person, !person.isDeleted else { continue }
                people[id] = person
            }
        }
        return ContactGroupPeople(peopleByResourceName: people, missingResourceNames: ids.filter { people[$0] == nil })
    }

    static func isPeopleResource(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix), value.utf8.count <= 1_024 else { return false }
        let id = value.dropFirst(prefix.count)
        return !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }
}
