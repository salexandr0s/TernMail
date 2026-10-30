import Foundation

public struct GoogleContactGroup: Decodable, Sendable, Equatable {
    public struct Metadata: Decodable, Sendable, Equatable { public let deleted: Bool? }
    public let resourceName: String
    public let name: String?
    public let groupType: String?
    public let memberCount: Int?
    public let memberResourceNames: [String]?
    public let metadata: Metadata?

    public var isUserGroup: Bool { groupType == "USER_CONTACT_GROUP" && metadata?.deleted != true }
}

public struct ContactGroupCatalog: Sendable, Equatable {
    public let groups: [GoogleContactGroup]
    public let isComplete: Bool
    public init(groups: [GoogleContactGroup], isComplete: Bool) { self.groups = groups; self.isComplete = isComplete }
}

public struct ContactGroupPeople: Sendable, Equatable {
    public let peopleByResourceName: [String: Person]
    public let missingResourceNames: [String]
    public init(peopleByResourceName: [String: Person], missingResourceNames: [String]) {
        self.peopleByResourceName = peopleByResourceName; self.missingResourceNames = missingResourceNames
    }
}

struct ContactGroupsResponse: Decodable {
    let contactGroups: [GoogleContactGroup]?
    let nextPageToken: String?
}

struct ContactGroupPeopleResponse: Decodable {
    struct Item: Decodable {
        struct Status: Decodable { let code: Int? }
        let requestedResourceName: String?
        let person: Person?
        let httpStatusCode: Int?
        let status: Status?
    }
    let responses: [Item]?
}
