import Foundation

/// A message-scoped capability for one consented remote image. The original
/// HTTPS address stays out of WebKit's network stack and is revalidated by the
/// native image loader before it makes a connection.
public enum RemoteImageResourceURL {
    public static let scheme = "tern-remote-image"
    public static let maximumCount = 128

    public static func make(_ original: URL, scope: String) -> URL? {
        guard HTMLSanitizer.isConsentLoadable(original), UUID(uuidString: scope) != nil else { return nil }
        let encoded = Data(original.absoluteString.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "\(scheme)://\(scope)/\(encoded)")
    }

    public static func original(for capability: URL, scope: String) -> URL? {
        guard capability.scheme == scheme, capability.host == scope, UUID(uuidString: scope) != nil,
              capability.user == nil, capability.password == nil, capability.port == nil,
              capability.query == nil, capability.fragment == nil,
              capability.path.split(separator: "/").count == 1,
              capability.absoluteString.utf8.count <= 12_000 else { return nil }
        var encoded = String(capability.path.dropFirst()).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded),
              let raw = String(data: bytes, encoding: .utf8),
              let original = URL(string: raw), make(original, scope: scope) == capability else { return nil }
        return original
    }
}
