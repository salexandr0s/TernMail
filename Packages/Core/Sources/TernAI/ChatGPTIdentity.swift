import Foundation
import Security

/// Validates identity against a fixed issuer and keys fetched from OpenAI's JWKS endpoint.
public enum ChatGPTIdentityVerifier {
    public static func verify(idToken: String, jwks: Data, clientID: String, nonce: String?,
                              expectedSubject: String?, now: Date = .now) throws -> ChatGPTAccountIdentity {
        guard validIdentifier(clientID), clientID != "dynamic_agent_client", idToken.utf8.count <= 16_384,
              jwks.count <= 65_536 else { throw ChatGPTAuthError.invalidIdentity }
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let headerData = Data(strictBase64URL: parts[0]), headerData.count <= 2048,
              let claimsData = Data(strictBase64URL: parts[1]), claimsData.count <= 12_288,
              let signature = Data(strictBase64URL: parts[2]), signature.count <= 1024 else {
            throw ChatGPTAuthError.invalidIdentity
        }
        do {
            let decoder = JSONDecoder()
            let header = try decoder.decode(Header.self, from: headerData)
            guard header.alg == "RS256", validIdentifier(header.kid),
                  let headerObject = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
                  ["jku", "jwk", "x5u", "crit"].allSatisfy({ headerObject[$0] == nil }) else {
                throw ChatGPTAuthError.invalidIdentity
            }
            let set = try decoder.decode(KeySet.self, from: jwks)
            guard !set.keys.isEmpty, set.keys.count <= 32,
                  set.keys.allSatisfy({ validIdentifier($0.kid) }),
                  Set(set.keys.map(\.kid)).count == set.keys.count,
                  let key = set.keys.first(where: { $0.kid == header.kid }),
                  key.kty == "RSA", key.use == nil || key.use == "sig",
                  key.alg == nil || key.alg == "RS256",
                  key.keyOps == nil || key.keyOps == ["verify"],
                  let modulus = Data(strictBase64URL: key.n), (256...1024).contains(modulus.count),
                  let first = modulus.first, first >= 128,
                  let exponent = Data(strictBase64URL: key.e), (1...4).contains(exponent.count),
                  exponent.first != 0, signature.count == modulus.count else { throw ChatGPTAuthError.invalidIdentity }
            let exponentValue = exponent.reduce(UInt64(0)) { $0 * 256 + UInt64($1) }
            guard exponentValue >= 3, exponentValue % 2 == 1 else { throw ChatGPTAuthError.invalidIdentity }
            let publicDER = der(0x30, integer(modulus) + integer(exponent))
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
                kSecAttrKeySizeInBits as String: modulus.count * 8,
            ]
            guard let publicKey = SecKeyCreateWithData(publicDER as CFData, attributes as CFDictionary, nil),
                  SecKeyIsAlgorithmSupported(publicKey, .verify, .rsaSignatureMessagePKCS1v15SHA256),
                  SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                    Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil) else {
                throw ChatGPTAuthError.invalidIdentity
            }
            let claims = try decoder.decode(Claims.self, from: claimsData)
            let audiences = claims.aud.values
            guard claims.iss == "https://auth.openai.com", validIdentifier(claims.sub),
                  !audiences.isEmpty, audiences.count <= 16, audiences.allSatisfy(validIdentifier),
                  Set(audiences).count == audiences.count, audiences.contains(clientID),
                  audiences.count == 1 || claims.azp == clientID,
                  claims.azp == nil || claims.azp == clientID,
                  numericDate(claims.exp), numericDate(claims.iat), claims.exp > claims.iat,
                  claims.iat <= now.timeIntervalSince1970 + 60,
                  claims.nbf.map({ numericDate($0) && $0 <= now.timeIntervalSince1970 + 60 && $0 < claims.exp }) ?? true else {
                throw ChatGPTAuthError.invalidIdentity
            }
            guard claims.exp > now.timeIntervalSince1970 else { throw ChatGPTAuthError.expiredToken }
            if let nonce {
                guard let actual = claims.nonce, constantTimeEqual(actual, nonce) else { throw ChatGPTAuthError.invalidIdentity }
            }
            if let expectedSubject, claims.sub != expectedSubject { throw ChatGPTAuthError.changedIdentity }
            guard claims.email.map(validDisplayText) ?? true, claims.name.map(validDisplayText) ?? true else {
                throw ChatGPTAuthError.invalidIdentity
            }
            return ChatGPTAccountIdentity(subject: claims.sub, email: claims.email, name: claims.name)
        } catch let error as ChatGPTAuthError {
            throw error
        } catch {
            throw ChatGPTAuthError.invalidIdentity
        }
    }

    private static func numericDate(_ value: Double) -> Bool {
        value.isFinite && value > 0 && value.rounded(.towardZero) == value
    }
    private static func validDisplayText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    private static func integer(_ bytes: Data) -> Data {
        let positive = bytes.first.map { $0 & 0x80 != 0 } ?? false
        return der(0x02, (positive ? Data([0]) : Data()) + bytes)
    }
    private static func der(_ tag: UInt8, _ payload: Data) -> Data {
        var length = [UInt8]()
        var count = payload.count
        repeat { length.insert(UInt8(count & 0xff), at: 0); count >>= 8 } while count > 0
        let prefix = payload.count < 128 ? [UInt8(payload.count)] : [0x80 | UInt8(length.count)] + length
        return Data([tag] + prefix) + payload
    }

    private struct Header: Decodable { let alg: String; let kid: String }
    private struct KeySet: Decodable { let keys: [Key] }
    private struct Key: Decodable {
        let kty: String; let kid: String; let n: String; let e: String
        let use: String?; let alg: String?; let keyOps: [String]?
        enum CodingKeys: String, CodingKey { case kty, kid, n, e, use, alg; case keyOps = "key_ops" }
    }
    private struct Claims: Decodable {
        let iss: String; let sub: String; let aud: Audience; let azp: String?
        let exp: Double; let iat: Double; let nbf: Double?; let nonce: String?
        let email: String?; let name: String?
    }
    private enum Audience: Decodable {
        case one(String), many([String])
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let value = try? container.decode(String.self) { self = .one(value) }
            else { self = .many(try container.decode([String].self)) }
        }
        var values: [String] { switch self { case .one(let value): [value]; case .many(let values): values } }
    }
}
