import Foundation
import MessageContent
import SyncEngine
import WebKit

/// WebKit sees only message-scoped image URLs. Network I/O happens in the
/// native pinned transport after the original HTTPS destination is validated.
@MainActor
final class RemoteImageHandler: NSObject, WKURLSchemeHandler {
    private var scope: String
    private var enabled: Bool
    private var isActive = true
    private var allowedURLs: Set<URL>
    private let fetch: @Sendable (URL) async throws -> PinnedRemoteImage
    private let limiter: RemoteImageLoadLimiter
    private struct Pending {
        let request: any WKURLSchemeTask
        let task: Task<Void, Never>
    }
    private var tasks: [ObjectIdentifier: Pending] = [:]

    init(scope: String, enabled: Bool, allowedURLs: Set<URL> = [],
         limiter: RemoteImageLoadLimiter = .shared,
         fetch: @escaping @Sendable (URL) async throws -> PinnedRemoteImage = { try await PinnedRemoteImageClient.load($0) }) {
        self.scope = scope
        self.enabled = enabled
        self.allowedURLs = allowedURLs
        self.limiter = limiter
        self.fetch = fetch
    }

    func update(scope: String, enabled: Bool, allowedURLs: Set<URL>) {
        guard self.scope != scope || self.enabled != enabled || self.allowedURLs != allowedURLs else { return }
        self.scope = scope
        self.enabled = enabled
        self.allowedURLs = allowedURLs
        cancelPending()
    }

    func cancelPending() {
        for id in Array(tasks.keys) {
            guard let item = tasks.removeValue(forKey: id) else { continue }
            item.task.cancel()
            item.request.didFailWithError(URLError(.cancelled))
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if !active { cancelPending() }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard enabled, isActive, let url = urlSchemeTask.request.url,
              let original = RemoteImageResourceURL.original(for: url, scope: scope),
              allowedURLs.contains(original), tasks.count < RemoteImageResourceURL.maximumCount else {
            urlSchemeTask.didFailWithError(URLError(.resourceUnavailable))
            return
        }
        let id = ObjectIdentifier(urlSchemeTask)
        let fetch = self.fetch
        let task = Task { [weak self, limiter] in
            do {
                let image = try await limiter.perform { try await fetch(original) }
                guard !Task.isCancelled, self?.tasks[id] != nil else { return }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: image.mimeType,
                    expectedContentLength: image.data.count, textEncodingName: nil))
                urlSchemeTask.didReceive(image.data)
                urlSchemeTask.didFinish()
            } catch {
                guard !Task.isCancelled, self?.tasks[id] != nil else { return }
                urlSchemeTask.didFailWithError(error)
            }
            self?.tasks[id] = nil
        }
        tasks[id] = Pending(request: urlSchemeTask, task: task)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        tasks.removeValue(forKey: id)?.task.cancel()
    }
}

/// A shared limit applies across visible messages. Cancelling a queued request
/// removes it before it starts DNS resolution or opens a connection.
@MainActor
final class RemoteImageLoadLimiter {
    static let shared = RemoteImageLoadLimiter(maximumConcurrentLoads: 4)
    private let maximumConcurrentLoads: Int
    private var active = 0
    private var waiting: [(UUID, CheckedContinuation<Bool, Never>)] = []
    var activeLoadCount: Int { active }
    var queuedLoadCount: Int { waiting.count }

    init(maximumConcurrentLoads: Int) { self.maximumConcurrentLoads = max(1, maximumConcurrentLoads) }

    func perform(_ fetch: @escaping @Sendable () async throws -> PinnedRemoteImage) async throws -> PinnedRemoteImage {
        let id = UUID()
        let admitted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                if active < maximumConcurrentLoads {
                    active += 1
                    continuation.resume(returning: true)
                } else { waiting.append((id, continuation)) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        guard admitted else { throw CancellationError() }
        defer { release() }
        try Task.checkCancellation()
        return try await fetch()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(returning: false)
    }

    private func release() {
        if waiting.isEmpty { active -= 1 }
        else { waiting.removeFirst().1.resume(returning: true) }
    }
}
