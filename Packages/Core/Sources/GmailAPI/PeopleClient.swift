import Foundation

/// Reads contacts from the People API for address suggestions. Requests go
/// through the same `GoogleSession` code as Gmail's.
public struct PeopleClient: Sendable {
    public enum Source: String, Sendable, CaseIterable {
        /// Saved contacts, `people.connections.list`. Needs `contacts.readonly`.
        case connections
        /// People the user has written to, `otherContacts.list`. Needs `contacts.other.readonly`.
        case otherContacts
    }

    static let host = "people.googleapis.com"
    /// The largest page both lists allow.
    static let pageSize = 1000
    /// Fields asked for on every person. A sync token works only with the
    /// fields that issued it, so callers store this with the token.
    public static let fields = "names,emailAddresses,metadata,photos"

    let session: GoogleSession

    public init(session: GoogleSession) {
        self.session = session
    }

    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = GoogleSession.defaultTransport) {
        self.init(session: GoogleSession(tokens: tokens, transport: transport))
    }

    /// One page of `source`. Pass `syncToken` for an incremental sync and
    /// `pageToken` for later pages; every other parameter stays the same, as
    /// the API requires.
    ///
    /// - Throws: For a request with a sync token, `PeopleError.syncTokenExpired`
    ///   when Google says the token has expired, and otherwise
    ///   `PeopleError.syncTokenRejected` for a 400 or 410.
    public func page(_ source: Source, syncToken: String? = nil, pageToken: String? = nil) async throws -> ContactPage {
        var query = [
            URLQueryItem(name: source == .connections ? "personFields" : "readMask", value: Self.fields),
            URLQueryItem(name: "pageSize", value: String(Self.pageSize)),
            URLQueryItem(name: "requestSyncToken", value: "true"),
        ]
        if let syncToken { query.append(URLQueryItem(name: "syncToken", value: syncToken)) }
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        let path = source == .connections ? "/v1/people/me/connections" : "/v1/otherContacts"

        let data: Data
        do {
            data = try await session.send(request(path: path, query: query)).data
        } catch GmailError.http(_, let reason) where syncToken != nil && reason == "EXPIRED_SYNC_TOKEN" {
            // The People API names the reason but not the status.
            throw PeopleError.syncTokenExpired
        } catch GmailError.http(let status, _) where syncToken != nil && (status == 400 || status == 410) {
            throw PeopleError.syncTokenRejected(status: status)
        }
        switch source {
        case .connections:
            let page: ConnectionsResponse = try session.decode(data)
            return ContactPage(people: page.connections ?? [], nextPageToken: page.nextPageToken, nextSyncToken: page.nextSyncToken)
        case .otherContacts:
            let page: OtherContactsResponse = try session.decode(data)
            return ContactPage(people: page.otherContacts ?? [], nextPageToken: page.nextPageToken, nextSyncToken: page.nextSyncToken)
        }
    }

    /// Every page of a full sync (no `syncToken`) or an incremental one. The
    /// returned token is the last page's, so a caller that stores it only
    /// after writing `people` never skips a page.
    public func sync(_ source: Source, syncToken: String? = nil) async throws -> ContactSync {
        var people: [Person] = []
        var pageToken: String?
        while true {
            let page = try await page(source, syncToken: syncToken, pageToken: pageToken)
            people += page.people
            guard let next = page.nextPageToken, !next.isEmpty else {
                return ContactSync(people: people, syncToken: page.nextSyncToken)
            }
            guard next != pageToken else { throw GmailError.decoding("ContactPage.nextPageToken") }
            pageToken = next
        }
    }

    /// `people.searchDirectoryPeople` over domain profiles and domain contacts,
    /// matching names and addresses by prefix. Needs `directory.readonly`.
    ///
    /// Blank text returns no results without a request, since `query` is
    /// required. `pageSize` is kept within the API's 1 to 500.
    ///
    /// - Throws: `PeopleError.directoryUnavailable` for a 403 that isn't a
    ///   missing scope or a rate limit.
    public func searchDirectory(_ text: String, pageSize: Int = 10, pageToken: String? = nil) async throws -> DirectoryPage {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return DirectoryPage(people: [], nextPageToken: nil) }
        var query = [
            URLQueryItem(name: "query", value: text),
            URLQueryItem(name: "readMask", value: "names,emailAddresses"),
            URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"),
            URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"),
            URLQueryItem(name: "pageSize", value: String(min(max(pageSize, 1), 500))),
        ]
        if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }

        let data: Data
        do {
            data = try await session.send(request(path: "/v1/people:searchDirectoryPeople", query: query)).data
        } catch let error as GmailError where !error.isMissingScope {
            guard case .http(status: 403, _) = error else { throw error }
            throw PeopleError.directoryUnavailable
        }
        let page: DirectoryResponse = try session.decode(data)
        return DirectoryPage(people: page.people ?? [], nextPageToken: page.nextPageToken)
    }

    func request(path: String, query: [URLQueryItem]) throws -> URLRequest {
        var components = URLComponents()
        components.scheme = "https"
        components.host = Self.host
        components.path = path
        components.queryItems = query
        // URLComponents leaves "+" as is, and Google decodes it as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw GmailError.invalidRequest(path) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }
}
