import Foundation
import MessageContent
import Network
import Security

public struct PinnedRemoteImage: Sendable {
    public let data: Data
    public let mimeType: String
    public init(data: Data, mimeType: String) {
        self.data = data
        self.mimeType = mimeType
    }
}

/// Loads consented mail images without granting WebKit access to the network.
/// DNS is checked once; the TLS connection uses that numeric address and
/// verifies the certificate against the original hostname.
public enum PinnedRemoteImageClient {
    public static let maximumBytes = 8 * 1_024 * 1_024
    private static let maximumTransferBytes = maximumBytes + 1_024 * 1_024
    private static let allowedTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]

    public static func load(_ url: URL) async throws -> PinnedRemoteImage {
        guard let safe = NewsletterURLPolicy.webURL(url.absoluteString, requiresHTTPS: true),
              let host = safe.host, let components = URLComponents(url: safe, resolvingAgainstBaseURL: false) else {
            throw NewsletterTransportError.unsafeURL
        }
        let addresses = try await NewsletterDNSCheck.resolve { NewsletterNetworkPolicy.publicAddresses(host) }
        guard let address = validatedAddress(addresses) else {
            throw NewsletterTransportError.unsafeURL
        }
        var target = components.percentEncodedPath
        if target.isEmpty { target = "/" }
        if let query = components.percentEncodedQuery { target += "?" + query }
        guard !target.contains("\r"), !target.contains("\n"), target.utf8.count <= 8_192 else {
            throw NewsletterTransportError.unsafeURL
        }
        let request = Data("GET \(target) HTTP/1.1\r\nHost: \(host)\r\nAccept: image/png,image/jpeg,image/gif,image/webp,image/avif\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n".utf8)
        let tls = NWProtocolTLS.Options()
        host.withCString { sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, $0) }
        let connection = PinnedNewsletterConnection(address: address,
            parameters: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { [weak connection] in
            connection?.fail(URLError(.timedOut))
        }
        return try await withTaskCancellationHandler {
            defer { connection.cancel() }
            try await connection.ready()
            try await connection.send(request)
            var received = Data()
            var complete = false
            var header: Header?
            var consumedHeaderBytes = 0
            while header == nil {
                let (chunk, finished) = try await connection.receive()
                if let chunk { received.append(chunk) }
                complete = finished
                guard received.count <= 16_384 + maximumTransferBytes else { throw URLError(.dataLengthExceedsMaximum) }
                _ = try PinnedNewsletterHTTP.finalResponseHeaders(in: &received, consumedHeaderBytes: &consumedHeaderBytes)
                header = try parseHeader(received)
                if complete && header == nil { throw NewsletterTransportError.invalidResponse }
            }
            guard let header else { throw NewsletterTransportError.invalidResponse }
            var body = Data(received[header.bodyStart...])
            if header.chunked {
                var decoder = ChunkedDecoder()
                var transferred = 0
                while true {
                    try Task.checkCancellation()
                    transferred += body.count
                    guard transferred <= maximumTransferBytes else { throw URLError(.dataLengthExceedsMaximum) }
                    if let decoded = try decoder.append(body) {
                        return PinnedRemoteImage(data: decoded, mimeType: header.mimeType)
                    }
                    guard !complete else { throw NewsletterTransportError.invalidResponse }
                    let (chunk, finished) = try await connection.receive()
                    body = chunk ?? Data()
                    complete = finished
                }
            }
            while true {
                try Task.checkCancellation()
                guard body.count <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
                if let length = header.contentLength, body.count >= length {
                    return PinnedRemoteImage(data: Data(body.prefix(length)), mimeType: header.mimeType)
                } else if complete {
                    guard header.contentLength == nil, !body.isEmpty, body.count <= maximumBytes else {
                        throw NewsletterTransportError.invalidResponse
                    }
                    return PinnedRemoteImage(data: body, mimeType: header.mimeType)
                }
                if complete { throw NewsletterTransportError.invalidResponse }
                let (chunk, finished) = try await connection.receive()
                if let chunk { body.append(chunk) }
                complete = finished
            }
        } onCancel: { connection.fail(CancellationError()) }
    }

    struct Header {
        let mimeType: String
        let contentLength: Int?
        let chunked: Bool
        let bodyStart: Data.Index
    }

    static func validatedAddress(_ addresses: [String]) -> String? {
        guard !addresses.isEmpty, addresses.allSatisfy(NewsletterNetworkPolicy.isPublicNumericAddress) else { return nil }
        return addresses.first
    }

    static func parseHeader(_ data: Data) throws -> Header? {
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 16_384 { throw NewsletterTransportError.invalidResponse }
            return nil
        }
        guard boundary.upperBound <= 16_384,
              let text = String(data: data[..<boundary.lowerBound], encoding: .utf8) else {
            throw NewsletterTransportError.invalidResponse
        }
        let lines = text.components(separatedBy: "\r\n")
        let status = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard status.count >= 2, ["HTTP/1.0", "HTTP/1.1"].contains(String(status[0])),
              status[1] == "200" else { throw NewsletterTransportError.invalidResponse }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), line.first != " ", line.first != "\t" else {
                throw NewsletterTransportError.invalidResponse
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if fields[name] != nil {
                // Set-Cookie and other irrelevant headers may repeat. Framing
                // and type headers must have one unambiguous value.
                if ["content-type", "content-length", "content-encoding", "transfer-encoding"].contains(name) {
                    throw NewsletterTransportError.invalidResponse
                }
                continue
            }
            fields[name] = value
        }
        let mime = fields["content-type"]?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard allowedTypes.contains(mime),
              fields["content-encoding"].map({ $0.lowercased() == "identity" }) ?? true else {
            throw NewsletterTransportError.invalidResponse
        }
        let chunked = fields["transfer-encoding"]?.lowercased() == "chunked"
        guard fields["transfer-encoding"] == nil || chunked else { throw NewsletterTransportError.invalidResponse }
        let length: Int?
        if let raw = fields["content-length"] {
            guard !chunked, let value = Int(raw), value > 0, value <= maximumBytes else {
                throw NewsletterTransportError.invalidResponse
            }
            length = value
        } else { length = nil }
        return Header(mimeType: mime, contentLength: length, chunked: chunked, bodyStart: boundary.upperBound)
    }

    /// Returns nil when a chunked response is incomplete. Extra data after the
    /// terminal chunk is ignored; it is never exposed as image bytes.
    static func decodeChunked(_ raw: Data) throws -> Data? {
        var decoder = ChunkedDecoder()
        return try decoder.append(raw)
    }

    /// Consumes each received byte once, retaining only an incomplete framing
    /// line and the decoded image. Small network fragments do not reparse it.
    struct ChunkedDecoder {
        private enum State {
            case size, data(Int), dataEnd, trailers, finished
            var isSize: Bool { if case .size = self { true } else { false } }
        }
        private var state = State.size
        private var pending = Data()
        private var output = Data()
        private var trailerBytes = 0

        mutating func append(_ bytes: Data) throws -> Data? {
            pending.append(bytes)
            var cursor = pending.startIndex
            defer { pending.removeSubrange(..<cursor) }
            while true {
                try Task.checkCancellation()
                let available = pending.endIndex - cursor
                switch state {
                case .size, .trailers:
                    let limit = state.isSize ? 128 : 4_096 - trailerBytes
                    guard let lineEnd = pending.range(of: Data("\r\n".utf8), in: cursor..<pending.endIndex) else {
                        guard available <= limit else { throw NewsletterTransportError.invalidResponse }
                        return nil
                    }
                    let count = lineEnd.lowerBound - cursor
                    guard count <= limit else { throw NewsletterTransportError.invalidResponse }
                    let line = Data(pending[cursor..<lineEnd.lowerBound])
                    cursor = lineEnd.upperBound
                    if state.isSize {
                        guard let text = String(data: line, encoding: .ascii),
                              let hex = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false).first, !hex.isEmpty,
                              hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                              let size = Int(hex, radix: 16), size <= maximumBytes - output.count else {
                            throw NewsletterTransportError.invalidResponse
                        }
                        state = size == 0 ? .trailers : .data(size)
                    } else {
                        trailerBytes += count + 2
                        guard trailerBytes <= 4_096 else { throw NewsletterTransportError.invalidResponse }
                        if count == 0 {
                            guard !output.isEmpty else { throw NewsletterTransportError.invalidResponse }
                            state = .finished
                            return output
                        }
                    }
                case .data(let remaining):
                    guard available > 0 else { return nil }
                    let count = min(available, remaining)
                    output.append(pending[cursor..<(cursor + count)])
                    cursor += count
                    state = count == remaining ? .dataEnd : .data(remaining - count)
                case .dataEnd:
                    guard available >= 2 else { return nil }
                    guard pending[cursor] == 13, pending[cursor + 1] == 10 else {
                        throw NewsletterTransportError.invalidResponse
                    }
                    cursor += 2
                    state = .size
                case .finished: return output
                }
            }
        }
    }
}
