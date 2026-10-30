import Foundation

extension GmailClient {
    // MARK: Filters

    /// `settings.filters.list`. Gmail returns them all at once, with no paging.
    public func filters() async throws -> [GmailFilter] {
        let list: FilterList = try decode(await send(.get("settings/filters")))
        return list.filter ?? []
    }

    /// `settings.filters.create`, which needs `gmail.settings.basic`. A failure
    /// that leaves the outcome unknown, such as a timeout, may still have
    /// created the filter.
    public func createFilter(criteria: GmailFilter.Criteria, action: GmailFilter.Action) async throws -> GmailFilter {
        let body = try encode(NewFilter(criteria: criteria, action: action))
        let created: GmailFilter = try decode(await send(.post("settings/filters", body: body)))
        guard created.id != nil else { throw GmailError.decoding("GmailFilter.id") }
        return created
    }

    /// `settings.filters.delete`, which needs `gmail.settings.basic`. A filter
    /// that's already gone counts as deleted.
    public func deleteFilter(id: String) async throws {
        let endpoint = Endpoint.delete("settings/filters/\(id)")
        do {
            _ = try await send(settingsRequest(endpoint, path: ["settings", "filters", id]))
        } catch GmailError.notFound {
            return
        }
    }

    // MARK: Vacation responder

    public func vacation() async throws -> VacationSettings {
        try decode(await send(.get("settings/vacation")))
    }

    /// `settings.updateVacation`, which needs `gmail.settings.basic`. It
    /// replaces the whole resource, so `settings` should start from a fresh read.
    public func updateVacation(_ settings: VacationSettings) async throws -> VacationSettings {
        try settings.validate()
        let body = try encode(settings)
        return try decode(await send(Endpoint(method: "PUT", path: "settings/vacation", query: [], body: body)))
    }

    // MARK: Send-as identities

    /// `settings.sendAs.list`, primary address included.
    public func sendAsIdentities() async throws -> [SendAsIdentity] {
        let list: SendAsList = try decode(await send(.get("settings/sendAs")))
        return list.sendAs ?? []
    }

    /// `settings.sendAs.patch` with only the signature. Needs `gmail.settings.basic`.
    public func updateSignature(sendAsEmail: String, signature: String) async throws -> SendAsIdentity {
        let endpoint = try Endpoint.patch("settings/sendAs/\(sendAsEmail)", body: encode(SignaturePatch(signature: signature)))
        return try decode(await send(settingsRequest(endpoint, path: ["settings", "sendAs", sendAsEmail])).data)
    }

    /// `endpoint` with its path rebuilt from `path`, each segment percent-encoded
    /// once. `Endpoint` alone would leave "+" in an address bare, and encode an
    /// escaped one twice.
    private func settingsRequest(_ endpoint: Endpoint, path: [String]) throws -> URLRequest {
        var request = try endpoint.urlRequest()
        var components = endpoint.components()
        let segments = try path.map { segment in
            guard let encoded = segment.addingPercentEncoding(withAllowedCharacters: .urlUnreserved) else {
                throw GmailError.invalidRequest("Settings path")
            }
            return encoded
        }
        components.percentEncodedPath = endpoint.base.rawValue + segments.joined(separator: "/")
        guard let url = components.url else { throw GmailError.invalidRequest("Settings path") }
        request.url = url
        return request
    }
}

extension CharacterSet {
    /// RFC 3986 unreserved characters, the only ones a path segment keeps as is.
    static let urlUnreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

private struct NewFilter: Encodable {
    let criteria: GmailFilter.Criteria
    let action: GmailFilter.Action
}

private struct SignaturePatch: Encodable {
    let signature: String
}
