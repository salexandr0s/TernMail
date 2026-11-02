import Foundation

public protocol TasksService: Sendable {
    func taskLists(pageToken: String?) async throws -> GoogleTaskListPage
    func tasks(listID: String, pageToken: String?) async throws -> GoogleTaskPage
    func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask
    func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String?) async throws -> GoogleTask
    func deleteTask(listID: String, taskID: String, etag: String?) async throws
}

extension TasksService {
    public func allTaskLists() async throws -> [GoogleTaskList] {
        var result: [GoogleTaskList] = []
        var token: String?
        var visited = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await taskLists(pageToken: token)
            result += page.items
            token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let token, !visited.insert(token).inserted {
                throw GmailError.decoding("Repeated task-list page token")
            }
        } while token != nil
        return result
    }

    public func allTasks(listID: String) async throws -> [GoogleTask] {
        var result: [GoogleTask] = []
        var token: String?
        var visited = Set<String>()
        repeat {
            try Task.checkCancellation()
            let page = try await tasks(listID: listID, pageToken: token)
            result += page.items.filter { $0.deleted != true }
            token = page.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
            if let token, !visited.insert(token).inserted {
                throw GmailError.decoding("Repeated task page token")
            }
        } while token != nil
        return result
    }
}

public struct GoogleTasksClient: TasksService, Sendable {
    private let session: GoogleSession

    public init(session: GoogleSession) { self.session = session }
    public init(tokens: any AccessTokenProvider, transport: any HTTPTransport = GoogleSession.defaultTransport) {
        session = GoogleSession(tokens: tokens, transport: transport)
    }

    public func taskLists(pageToken: String? = nil) async throws -> GoogleTaskListPage {
        let request = try request(["users", "@me", "lists"], query: pageQuery(pageToken, maximum: 1000))
        let page: GoogleTaskListPage = try await resource(request)
        try validateIDs(page.items.map(\.id))
        return page
    }

    public func tasks(listID: String, pageToken: String? = nil) async throws -> GoogleTaskPage {
        let query = pageQuery(pageToken, maximum: 100) + [
            URLQueryItem(name: "showCompleted", value: "true"),
            // Google hides tasks completed in its own clients unless both flags are true.
            URLQueryItem(name: "showHidden", value: "true"),
            URLQueryItem(name: "showDeleted", value: "false"),
            URLQueryItem(name: "showAssigned", value: "true"),
        ]
        let page: GoogleTaskPage = try await resource(request(["lists", listID, "tasks"], query: query))
        try validateIDs(page.items.map(\.id))
        return page
    }

    public func insertTask(listID: String, draft: GoogleTaskDraft) async throws -> GoogleTask {
        let task: GoogleTask = try await resource(request(["lists", listID, "tasks"], method: "POST", body: session.encode(draft)))
        try validateIDs([task.id])
        return task
    }

    public func updateTask(listID: String, taskID: String, update: GoogleTaskUpdate, etag: String? = nil) async throws -> GoogleTask {
        let task: GoogleTask = try await resource(request(["lists", listID, "tasks", taskID], method: "PATCH",
                                                        body: session.encode(update), etag: etag))
        try validateIDs([task.id])
        return task
    }

    public func deleteTask(listID: String, taskID: String, etag: String? = nil) async throws {
        _ = try await session.send(request(["lists", listID, "tasks", taskID], method: "DELETE", etag: etag))
    }

    private func pageQuery(_ token: String?, maximum: Int) -> [URLQueryItem] {
        var query = [URLQueryItem(name: "maxResults", value: String(maximum))]
        if let token { query.append(URLQueryItem(name: "pageToken", value: token)) }
        return query
    }

    private func validateIDs(_ ids: [String]) throws {
        guard !ids.contains(where: \.isEmpty) else { throw GmailError.decoding("Task resource identity") }
    }

    private func request(_ segments: [String], method: String = "GET", query: [URLQueryItem] = [],
                         body: Data? = nil, etag: String? = nil) throws -> URLRequest {
        guard !segments.contains(where: \.isEmpty) else { throw GmailError.invalidRequest("Task resource identity") }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let encoded = try segments.map { segment in
            guard let value = segment.addingPercentEncoding(withAllowedCharacters: allowed) else {
                throw GmailError.invalidRequest("Task resource identity")
            }
            return value
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "tasks.googleapis.com"
        components.percentEncodedPath = "/tasks/v1/" + encoded.joined(separator: "/")
        if !query.isEmpty {
            components.queryItems = query
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else { throw GmailError.invalidRequest("Task request") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        return request
    }

    private func resource<Value: Decodable>(_ request: URLRequest) async throws -> Value {
        // Google Tasks assigns IDs. A transient retry of POST can duplicate a task.
        // GoogleSession only refreshes once after an explicit 401 rejection here.
        try session.decode(try await session.send(request).data)
    }
}
