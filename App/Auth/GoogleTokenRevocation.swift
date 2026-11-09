import Foundation
import GmailAPI

/// Asks Google to revoke a signed-out account's grant, which removes Tern
/// from the account's third-party connections. It's best effort: sign-out
/// goes ahead whatever the answer and waits at most `timeout` for one.
struct GoogleTokenRevocation: Sendable {
    static let endpoint = URL(string: "https://oauth2.googleapis.com/revoke")

    let timeout: Duration
    private let transport: any HTTPTransport

    init(timeout: Duration = .seconds(5), transport: any HTTPTransport = GoogleSession.defaultTransport) {
        self.timeout = timeout
        self.transport = transport
    }

    /// True once Google confirms the grant is gone. False for any other
    /// answer, a failed request, or no answer within `timeout`.
    func revoke(refreshToken: String) async -> Bool {
        guard let request = Self.request(revoking: refreshToken) else { return false }
        let (outcome, continuation) = AsyncStream.makeStream(of: Bool.self)
        let sending = Task { [transport] in
            var revoked = false
            if let answer = try? await transport.send(request) {
                revoked = Self.confirmsRevocation(data: answer.0, response: answer.1)
            }
            continuation.yield(revoked)
            continuation.finish()
        }
        let deadline = Task { [timeout] in
            try? await Task.sleep(for: timeout)
            continuation.yield(false)
            continuation.finish()
        }
        defer {
            sending.cancel()
            deadline.cancel()
        }
        for await revoked in outcome { return revoked }
        return false
    }

    /// A form-encoded POST. The token goes in the body, never in the URL,
    /// so it can't show up where URLs get recorded.
    static func request(revoking token: String) -> URLRequest? {
        guard let endpoint, !token.isEmpty,
              let value = token.addingPercentEncoding(withAllowedCharacters: unreserved) else { return nil }
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("token=\(value)".utf8)
        return request
    }

    /// Google answers 200 when it revokes the grant, and 400 `invalid_token`
    /// when the token was already revoked or expired.
    static func confirmsRevocation(data: Data, response: HTTPURLResponse) -> Bool {
        switch response.statusCode {
        case 200: true
        case 400: (try? JSONDecoder().decode(ErrorBody.self, from: data))?.error == "invalid_token"
        default: false
        }
    }

    private struct ErrorBody: Decodable { let error: String }

    /// Letters, digits and "-._~". Anything else in a token, such as "/", "+"
    /// or "=", is percent-encoded so the form body carries the exact value.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
