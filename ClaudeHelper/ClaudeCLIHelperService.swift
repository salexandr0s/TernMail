import Darwin
import Foundation

final class ClaudeCLIHelperListener: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard connection.effectiveUserIdentifier == geteuid(), let requirement = ClaudeCLICallerValidation.requirement() else { return false }
        connection.setCodeSigningRequirement(requirement)
        let service = ClaudeCLIHelperService(connection: connection)
        connection.exportedInterface = NSXPCInterface(with: ClaudeCLIHelperProtocol.self)
        connection.remoteObjectInterface = NSXPCInterface(with: ClaudeCLIClientProtocol.self)
        connection.exportedObject = service
        connection.invalidationHandler = { service.disconnect() }
        connection.interruptionHandler = { service.disconnect() }
        connection.resume()
        return true
    }
}

/// The XPC connection is used only to send callbacks. All mutable job ownership
/// and process state live in the runtime actor and its serial process queues.
private final class ClaudeCLIHelperService: NSObject, ClaudeCLIHelperProtocol, @unchecked Sendable {
    private weak var connection: NSXPCConnection?
    private let owner = UUID()
    private let runtime = ClaudeCLIHelperRuntime.shared

    init(connection: NSXPCConnection) { self.connection = connection }

    func status(_ requestID: String, withReply reply: @escaping @Sendable (Data) -> Void) {
        Task { reply(Self.encode(await runtime.status(owner: owner, requestID: requestID))) }
    }

    func login(_ requestID: String, withReply reply: @escaping @Sendable (Data) -> Void) {
        perform(reply) { try await self.runtime.login(owner: self.owner, requestID: requestID, receive: self.receiver(requestID)) }
    }

    func submitLoginCode(_ code: String, requestID: String, withReply reply: @escaping @Sendable (Data) -> Void) {
        perform(reply) { try await self.runtime.submitLoginCode(owner: self.owner, requestID: requestID, code: code) }
    }

    func run(_ request: Data, requestID: String, withReply reply: @escaping @Sendable (Data) -> Void) {
        perform(reply) { try await self.runtime.run(owner: self.owner, requestID: requestID, data: request, receive: self.receiver(requestID)) }
    }

    func cancel(_ requestID: String) { Task { await runtime.cancel(owner: owner, requestID: requestID) } }
    func disconnect() { Task { await runtime.disconnect(owner: owner) } }

    private func receiver(_ requestID: String) -> @Sendable (Data) -> Void {
        { [weak self] line in
            guard let self else { return }
            (self.connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in self?.disconnect() } as? ClaudeCLIClientProtocol)?
                .receive(line, requestID: requestID)
        }
    }

    private func perform(_ reply: @escaping @Sendable (Data) -> Void, operation: @escaping @Sendable () async throws -> Void) {
        Task {
            do { try await operation(); reply(Self.encode(ClaudeCLIHelperReply(success: true))) }
            catch {
                let code = (error as? ClaudeCLIHelperError)?.rawValue ?? "processFailed"
                reply(Self.encode(ClaudeCLIHelperReply(success: false, errorCode: code)))
            }
        }
    }

    private static func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data(#"{"success":false,"errorCode":"invalidOutput"}"#.utf8)
    }
}
