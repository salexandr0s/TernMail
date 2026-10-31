import AppKit
import Foundation
import Observation
import TernAI

enum AssistantRuntimeEnvironment {
    static var isTestHost: Bool {
        let process = ProcessInfo.processInfo
        return process.environment["XCTestConfigurationFilePath"] != nil
            || process.environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.allBundles.contains { $0.bundleURL.pathExtension == "xctest" }
    }
}

@MainActor
struct ChatGPTConnectionAuth {
    var exchange: (ChatGPTAuthorizationCode, ChatGPTAuthorizationAttempt) async throws -> ChatGPTPendingTokens
    var refresh: (ChatGPTCredentials) async throws -> ChatGPTPendingTokens
    var verify: (ChatGPTPendingTokens) async throws -> ChatGPTCredentials
    var revoke: (ChatGPTRegistration, String) async throws -> Void

    static var live: Self {
        let service = ChatGPTAuthorization()
        return Self(
            exchange: { try await service.exchange(code: $0, attempt: $1) },
            refresh: { try await service.refresh(credentials: $0) },
            verify: { try await service.verify($0) },
            revoke: { try await service.revoke(registration: $0, refreshToken: $1) }
        )
    }
}

struct ChatGPTStoredConnection: Codable {
    var version = 1
    var hostID = ChatGPTRegistration.newHostID()
    var registration: ChatGPTRegistration?
    var credentials: ChatGPTCredentials?
    var pending: ChatGPTPendingTokens?
    /// A crash after dispatch cannot safely retry the old rotating refresh token.
    var refreshDispatched = false
}

/// Owns one active ChatGPT registration, separate from all Gmail account credentials.
@MainActor
@Observable
final class ChatGPTConnection {
    private(set) var account: ChatGPTAccountIdentity?
    private(set) var registration: ChatGPTRegistration?
    private(set) var isConnecting = false
    private(set) var isDisconnecting = false
    private(set) var isRestoring = false
    private(set) var needsStorageRetry = false
    private(set) var errorMessage: String?
    private(set) var connectionRevision = 0

    var canUsePlan: Bool {
        storageLoaded && !locallyDisconnected && !isConnecting && !isDisconnecting && (!record.refreshDispatched || refreshTask != nil)
            && record.credentials?.canUsePlan == true
    }

    @ObservationIgnored private let store: any AIConnectionStore
    @ObservationIgnored private let auth: ChatGPTConnectionAuth
    @ObservationIgnored private let makeListener: () -> any ChatGPTCallbackListener
    @ObservationIgnored private let openBrowser: (URL) -> Bool
    @ObservationIgnored private let now: () -> Date
    private var record = ChatGPTStoredConnection()
    private var locallyDisconnected = false
    private var storageLoaded = false
    @ObservationIgnored private var storageFailure: (any Error)?
    @ObservationIgnored private var restorationTask: Task<Void, any Error>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var listener: (any ChatGPTCallbackListener)?
    @ObservationIgnored private var signInTask: Task<Void, Never>?
    @ObservationIgnored private var cancelledSignInTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<ChatGPTCredentials, any Error>?
    @ObservationIgnored private var signInHasCheckpoint = false
    @ObservationIgnored private var cancellationRevocation: Task<Bool, Never>?
    @ObservationIgnored private var cancellationCleanup: Task<Void, Never>?

    init(store: (any AIConnectionStore)? = nil, auth: ChatGPTConnectionAuth = .live,
         makeListener: @escaping () -> any ChatGPTCallbackListener = { LoopbackAuthListener() },
         openBrowser: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
         now: @escaping () -> Date = { .now }) {
        self.store = store ?? Self.defaultStore()
        self.auth = auth; self.makeListener = makeListener; self.openBrowser = openBrowser; self.now = now
        // Constructing a scene must never wait for a Keychain authorization dialog.
        locallyDisconnected = self.store.isDisconnected
    }

    private static func defaultStore() -> any AIConnectionStore {
        let process = ProcessInfo.processInfo
        if AssistantRuntimeEnvironment.isTestHost { return VolatileAIConnectionStore() }
        guard process.arguments.contains("--ui-audit") else { return AIKeychainStore() }
        #if DEBUG
        // Explicit live-auth audits retain synthetic mail while exercising the
        // app's own connection persistence across preview relaunches.
        if process.arguments.contains("--ui-audit-live-chatgpt") { return AIKeychainStore() }
        #endif
        return VolatileAIConnectionStore()
    }

    func connect() async {
        guard !isConnecting, !isDisconnecting else { return }
        let previousSignIn = cancelledSignInTask
        let previousCleanup = cancellationCleanup
        let previousRevocation = cancellationRevocation
        cancelledSignInTask = nil
        cancellationCleanup = nil
        cancellationRevocation = nil
        // Claim the operation before its first suspension, including storage access.
        generation += 1
        let expected = generation
        connectionRevision += 1
        isConnecting = true
        signInHasCheckpoint = false
        errorMessage = nil
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            defer {
                if generation == expected { signInTask = nil; isConnecting = false }
            }
            if let previousSignIn { await previousSignIn.value }
            if let previousCleanup { await previousCleanup.value }
            if let previousRevocation { _ = await previousRevocation.value }
            do {
                try ensureCurrent(expected)
                try await ensureStorageLoaded()
                try ensureCurrent(expected)
                if let refreshTask { _ = try? await refreshTask.value }
                try ensureCurrent(expected)
                // Persist the installation ID before opening a browser.
                try await save()
                try ensureCurrent(expected)
                await performSignIn(generation: expected)
            } catch {
                if generation == expected, !(error is CancellationError) { errorMessage = safeMessage(error) }
            }
        }
        signInTask = task
        await withTaskCancellationHandler { await task.value } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                self.cancelSignIn()
            }
        }
    }

    /// Finish a stored token checkpoint without starting a new browser authorization.
    func recoverPendingConnection() async {
        guard !isConnecting, !isDisconnecting else { return }
        do {
            try await ensureStorageLoaded()
            guard record.pending != nil, !locallyDisconnected, !isConnecting, !isDisconnecting else { return }
            _ = try await refreshedToken()
        }
        catch { errorMessage = safeMessage(error) }
    }

    /// Retry only storage access; this never opens a browser or replaces a registration.
    func retryStoredConnection() async {
        guard !isConnecting, !isDisconnecting else { return }
        do { try await ensureStorageLoaded(retry: true) }
        catch { errorMessage = safeMessage(error) }
    }

    func cancelSignIn() {
        guard isConnecting else { return }
        generation += 1
        connectionRevision += 1
        isConnecting = false
        listener?.cancel(); listener = nil
        cancelledSignInTask = signInTask
        signInTask?.cancel(); signInTask = nil
        // A cancelled login must not reconnect silently on the next request.
        if signInHasCheckpoint, let pending = record.pending {
            record.pending = nil
            record.credentials = nil
            locallyDisconnected = true
            store.setDisconnected(true)
            let cleared = record
            let cancelled = cancelledSignInTask
            let expected = generation
            cancellationCleanup = Task { [self] in
                // An in-flight credential write must finish before its clear.
                if let cancelled { await cancelled.value }
                do { try await store.save(JSONEncoder().encode(cleared)) }
                catch { if generation == expected { errorMessage = safeMessage(error) } }
            }
            publish()
            _ = revokeCancelledAuthorization(pending)
        }
        signInHasCheckpoint = false
    }

    func disconnect() async {
        guard !isDisconnecting else { return }
        cancelSignIn()
        isDisconnecting = true
        locallyDisconnected = true
        store.setDisconnected(true)
        connectionRevision += 1
        errorMessage = nil
        account = nil
        if let cancelledSignInTask {
            await cancelledSignInTask.value
            self.cancelledSignInTask = nil
        }
        if let cancellationCleanup {
            await cancellationCleanup.value
            self.cancellationCleanup = nil
        }
        // A failed read is not an empty record. Never overwrite an unread registration.
        do { try await ensureStorageLoaded(retry: true) }
        catch { errorMessage = "Disconnected. Tern still needs Keychain access to clear the stored ChatGPT credentials." }
        // Complete any dispatched rotation before choosing which token to revoke.
        if let refreshTask { _ = try? await refreshTask.value }
        generation += 1
        let pending = record.pending
        let credentials = record.credentials
        record.pending = nil; record.credentials = nil; record.refreshDispatched = false
        do { if storageLoaded { try await save() } }
        catch { errorMessage = "Disconnected. Tern still needs Keychain access to clear the stored ChatGPT credentials." }
        if let cancellationRevocation {
            if !(await cancellationRevocation.value), errorMessage == nil {
                errorMessage = "Disconnected from Tern. Remote revocation could not be confirmed; manage access in ChatGPT Settings."
            }
            self.cancellationRevocation = nil
        }
        let token = pending?.refreshToken ?? credentials?.refreshToken
        let tokenRegistration = pending?.registration ?? credentials?.registration
        if let token, let tokenRegistration {
            do { try await auth.revoke(tokenRegistration, token) }
            catch {
                if errorMessage == nil {
                    errorMessage = "Disconnected from Tern. Remote revocation could not be confirmed; manage access in ChatGPT Settings."
                }
            }
        }
        isDisconnecting = false
        publish()
    }

    func accessToken() async throws -> String {
        try Task.checkCancellation()
        guard !locallyDisconnected, !isConnecting, !isDisconnecting else { throw ChatGPTConnectionError.notConnected }
        try await ensureStorageLoaded()
        try Task.checkCancellation()
        guard !locallyDisconnected, !isConnecting, !isDisconnecting else { throw ChatGPTConnectionError.notConnected }
        if record.refreshDispatched, refreshTask == nil {
            throw ChatGPTAuthError.renewalUncertain
        }
        guard let existing = record.credentials, existing.canUsePlan else {
            if record.pending == nil {
                throw account == nil ? ChatGPTConnectionError.notConnected : ChatGPTConnectionError.planPermission
            }
            return try await refreshedToken()
        }
        if record.pending != nil || existing.needsRefresh(at: now()) {
            if record.pending == nil, let earliest = existing.earliestRefreshAt,
               earliest > now(), existing.expiresAt > now() {
                return existing.accessToken
            }
            return try await refreshedToken()
        }
        return existing.accessToken
    }

    private func refreshedToken() async throws -> String {
        let expected = generation
        let task: Task<ChatGPTCredentials, any Error>
        if let refreshTask { task = refreshTask }
        else {
            task = Task { [self] in
                defer { refreshTask = nil }
                return try await renew()
            }
            refreshTask = task
        }
        do {
            let credentials = try await task.value
            try Task.checkCancellation()
            guard expected == generation, !isConnecting, !isDisconnecting else { throw ChatGPTConnectionError.invalidated }
            guard credentials.canUsePlan else { throw ChatGPTConnectionError.planPermission }
            return credentials.accessToken
        } catch {
            if expected == generation, !isDisconnecting, !(error is CancellationError) {
                errorMessage = safeMessage(error)
            }
            throw error
        }
    }

    private func renew() async throws -> ChatGPTCredentials {
        let expected = generation
        do {
            let pending: ChatGPTPendingTokens
            if let saved = record.pending {
                pending = saved
                // Retry a failed Keychain checkpoint before exposing its replacement.
                try await save()
            } else {
                guard let credentials = record.credentials else { throw ChatGPTConnectionError.notConnected }
                record.refreshDispatched = true
                do { try await save() }
                catch { record.refreshDispatched = false; throw error }
                guard generation == expected, !isDisconnecting else {
                    record.refreshDispatched = false
                    try? await save()
                    throw ChatGPTConnectionError.invalidated
                }
                do { pending = try await auth.refresh(credentials) }
                catch {
                    if error as? ChatGPTAuthError != .renewalUncertain {
                        record.refreshDispatched = false
                        try? await save()
                    }
                    throw error
                }
                record.pending = pending
                record.refreshDispatched = false
                try await save()
            }
            guard generation == expected, !isDisconnecting else { throw ChatGPTConnectionError.invalidated }
            let credentials = try await auth.verify(pending)
            try await install(credentials, generation: expected)
            return credentials
        } catch {
            if let failure = error as? ChatGPTAuthError,
               [.invalidGrant, .renewalUncertain, .changedIdentity, .invalidIdentity].contains(failure) {
                record.credentials = nil
                // Keep an unverified replacement only for recovery or revocation.
                if failure == .invalidGrant || failure == .renewalUncertain { record.pending = nil }
                try? await save()
                connectionRevision += 1
                publish()
            }
            throw error
        }
    }

    private func performSignIn(generation expected: Int) async {
        let callbackListener = makeListener()
        listener = callbackListener
        defer {
            callbackListener.cancel()
            if generation == expected {
                listener = nil; signInTask = nil; isConnecting = false
            }
        }
        do {
            let redirect = try await callbackListener.start()
            try ensureCurrent(expected)
            let attempt = try ChatGPTAuthorizationAttempt(hostID: record.hostID, redirectURI: redirect,
                registration: record.registration, now: now(),
                requestConsent: record.credentials?.canUsePlan == false)
            callbackListener.expect(state: attempt.state)
            guard openBrowser(try attempt.authorizationURL) else { throw ChatGPTConnectionError.browserUnavailable }
            let callback = try await callbackListener.callback()
            try ensureCurrent(expected)
            let code = try attempt.validateCallback(callback, now: now())
            record.registration = code.registration
            try await save()
            try ensureCurrent(expected)
            registration = code.registration
            let pending = try await auth.exchange(code, attempt)
            do { try ensureCurrent(expected) }
            catch {
                // Some transports finish an exchange despite cancellation. The
                // returned renewable session must still be revoked, and an
                // awaiting disconnect must observe that revocation's outcome.
                if let cleanup = revokeCancelledAuthorization(pending) { _ = await cleanup.value }
                throw error
            }
            record.pending = pending; record.credentials = nil; record.refreshDispatched = false
            signInHasCheckpoint = true
            try await save()
            try ensureCurrent(expected)
            // This durable checkpoint belongs to a newly authorized login. It
            // may recover after a transient identity-verification failure, even
            // if the previous connection was explicitly disconnected.
            locallyDisconnected = false
            store.setDisconnected(false)
            publish()
            let credentials = try await auth.verify(pending)
            try ensureCurrent(expected)
            try await install(credentials, generation: expected)
            try ensureCurrent(expected)
            locallyDisconnected = false
            store.setDisconnected(false)
            signInHasCheckpoint = false
            publish()
            connectionRevision += 1
        } catch {
            if generation == expected, !(error is CancellationError) { errorMessage = safeMessage(error) }
        }
    }

    private func ensureCurrent(_ expected: Int) throws {
        try Task.checkCancellation()
        guard generation == expected, isConnecting, !isDisconnecting else { throw CancellationError() }
    }

    private func revokeCancelledAuthorization(_ pending: ChatGPTPendingTokens) -> Task<Bool, Never>? {
        guard let token = pending.refreshToken else { return nil }
        let task = Task { [auth] in
            do { try await auth.revoke(pending.registration, token); return true }
            catch { return false }
        }
        cancellationRevocation = task
        let cancelledGeneration = generation
        Task { [weak self] in
            if !(await task.value), self?.generation == cancelledGeneration,
               self?.isDisconnecting == false {
                self?.errorMessage = "Sign-in was cancelled. Remote revocation could not be confirmed; manage access in ChatGPT Settings."
            }
        }
        return task
    }

    private func ensureStorageLoaded(retry: Bool = false) async throws {
        if storageLoaded { return }
        if let restorationTask { return try await restorationTask.value }
        if let storageFailure, !retry { throw storageFailure }
        isRestoring = true
        let task = Task<Void, any Error> { [self] in
            defer { restorationTask = nil; isRestoring = false }
            do {
                if needsStorageRetry { errorMessage = nil }
                try await load()
                storageFailure = nil
                needsStorageRetry = false
            } catch {
                storageFailure = error
                needsStorageRetry = true
                errorMessage = safeMessage(error)
                throw error
            }
        }
        restorationTask = task
        try await task.value
    }

    private func load() async throws {
        if let data = try await store.load() {
            guard data.count <= 1_048_576,
                  let restored = try? JSONDecoder().decode(ChatGPTStoredConnection.self, from: data),
                  restored.version == 1,
                  restored.registration.map({ $0.hostID == restored.hostID }) ?? true,
                  restored.credentials.map({ $0.registration == restored.registration }) ?? true,
                  restored.pending.map({ $0.registration.clientID == restored.registration?.clientID }) ?? true else {
                throw ChatGPTConnectionError.malformedStorage
            }
            record = restored
        }
        locallyDisconnected = store.isDisconnected
        publish()
        if locallyDisconnected, !isDisconnecting, record.credentials != nil || record.pending != nil {
            var cleared = record
            cleared.credentials = nil; cleared.pending = nil; cleared.refreshDispatched = false
            try await store.save(JSONEncoder().encode(cleared))
            record = cleared
        } else if record.refreshDispatched {
            errorMessage = ChatGPTAuthError.renewalUncertain.localizedDescription
        }
        storageLoaded = true
    }

    private func save() async throws { try await store.save(JSONEncoder().encode(record)) }

    private func install(_ credentials: ChatGPTCredentials, generation expected: Int) async throws {
        var next = record
        next.registration = credentials.registration
        next.credentials = credentials
        next.pending = nil
        next.refreshDispatched = false
        // Keep the pending checkpoint until the verified replacement is durable.
        try await store.save(JSONEncoder().encode(next))
        guard generation == expected, !isDisconnecting else { throw ChatGPTConnectionError.invalidated }
        let changedIdentity = record.credentials?.account != credentials.account
            || record.credentials?.canUsePlan != credentials.canUsePlan
        record = next
        publish()
        if changedIdentity { connectionRevision += 1 }
    }

    private func publish() {
        registration = record.registration
        if !isDisconnecting { account = locallyDisconnected ? nil : record.credentials?.account }
    }

    private func safeMessage(_ error: any Error) -> String {
        if let error = error as? ChatGPTAuthError { return error.localizedDescription }
        if let error = error as? ChatGPTConnectionError { return error.localizedDescription }
        if error is AIKeychainFailure { return AIKeychainFailure().localizedDescription }
        return "Tern could not complete the ChatGPT connection. Please try again."
    }
}
