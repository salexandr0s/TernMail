import Foundation
import Security
import Testing
@testable import TernAI

struct ChatGPTIdentityTests {
    @Test func verifiesSignedIdentityAndAudienceArray() throws {
        let signer = try AuthTestSigner()
        let token = try signer.token(overrides: ["aud": ["oaiapp_tern", "other"], "azp": "oaiapp_tern"])
        let identity = try ChatGPTIdentityVerifier.verify(idToken: token, jwks: signer.jwks,
            clientID: "oaiapp_tern", nonce: "expected-nonce", expectedSubject: nil, now: AuthTestSigner.now)
        #expect(identity.subject == "account-subject")
        #expect(identity.email == "test@example.invalid")
    }

    @Test func rejectsWrongSignatureAndClaims() throws {
        let signer = try AuthTestSigner()
        let otherSigner = try AuthTestSigner()
        let valid = try signer.token()
        #expect(throws: ChatGPTAuthError.invalidIdentity) {
            try ChatGPTIdentityVerifier.verify(idToken: valid, jwks: otherSigner.jwks,
                clientID: "oaiapp_tern", nonce: "expected-nonce", expectedSubject: nil, now: AuthTestSigner.now)
        }
        let invalidClaims: [[String: Any]] = [
            ["iss": "https://example.invalid"], ["aud": "another-app"], ["nonce": "other-nonce"],
            ["aud": ["oaiapp_tern", "other"]], ["azp": "other"],
            ["iat": AuthTestSigner.now.timeIntervalSince1970 + 120],
        ]
        for claims in invalidClaims {
            let token = try signer.token(overrides: claims)
            #expect(throws: ChatGPTAuthError.invalidIdentity) {
                try ChatGPTIdentityVerifier.verify(idToken: token, jwks: signer.jwks,
                    clientID: "oaiapp_tern", nonce: "expected-nonce", expectedSubject: nil, now: AuthTestSigner.now)
            }
        }
        #expect(throws: ChatGPTAuthError.changedIdentity) {
            try ChatGPTIdentityVerifier.verify(idToken: valid, jwks: signer.jwks,
                clientID: "oaiapp_tern", nonce: "expected-nonce", expectedSubject: "different-account", now: AuthTestSigner.now)
        }
        #expect(throws: ChatGPTAuthError.expiredToken) {
            try ChatGPTIdentityVerifier.verify(idToken: valid, jwks: signer.jwks,
                clientID: "oaiapp_tern", nonce: "expected-nonce", expectedSubject: nil,
                now: AuthTestSigner.now.addingTimeInterval(3600))
        }
    }

    @Test func rejectsAlgorithmSubstitutionAndDuplicateSigningKey() throws {
        let signer = try AuthTestSigner()
        let wrongAlgorithm = try signer.token(algorithm: "HS256")
        #expect(throws: ChatGPTAuthError.invalidIdentity) {
            try ChatGPTIdentityVerifier.verify(idToken: wrongAlgorithm, jwks: signer.jwks,
                clientID: "oaiapp_tern", nonce: "expected-nonce", expectedSubject: nil, now: AuthTestSigner.now)
        }
        let duplicate = try JSONSerialization.data(withJSONObject: ["keys": [signer.key, signer.key]])
        let token = try signer.token()
        #expect(throws: ChatGPTAuthError.invalidIdentity) {
            try ChatGPTIdentityVerifier.verify(idToken: token, jwks: duplicate,
                clientID: "oaiapp_tern", nonce: "expected-nonce", expectedSubject: nil, now: AuthTestSigner.now)
        }
    }
}

/// Transient RSA keys sign controlled identity fixtures; no account or Keychain item is used.
struct AuthTestSigner {
    static let now = Date(timeIntervalSince1970: 1_793_000_000)
    let privateKey: SecKey
    let key: [String: String]
    let jwks: Data

    init() throws {
        privateKey = try #require(SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
        ] as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let exported = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        var outer = TestDERReader(bytes: Array(exported))
        var sequence = TestDERReader(bytes: try outer.read(tag: 0x30))
        var modulus = try sequence.read(tag: 0x02)
        if modulus.first == 0 { modulus.removeFirst() }
        let exponent = try sequence.read(tag: 0x02)
        key = ["kty": "RSA", "kid": "test-signing-key", "use": "sig", "alg": "RS256",
               "n": Data(modulus).base64URL, "e": Data(exponent).base64URL]
        jwks = try JSONSerialization.data(withJSONObject: ["keys": [key]])
    }

    func token(overrides: [String: Any] = [:], algorithm: String = "RS256") throws -> String {
        var claims: [String: Any] = [
            "iss": "https://auth.openai.com", "sub": "account-subject", "aud": "oaiapp_tern",
            "iat": Self.now.timeIntervalSince1970 - 30, "exp": Self.now.timeIntervalSince1970 + 3600,
            "nonce": "expected-nonce", "email": "test@example.invalid", "name": "Test Account",
        ]
        claims.merge(overrides, uniquingKeysWith: { _, new in new })
        let header = try JSONSerialization.data(withJSONObject: ["alg": algorithm, "kid": "test-signing-key"])
        let payload = try JSONSerialization.data(withJSONObject: claims)
        let input = header.base64URL + "." + payload.base64URL
        let signature = try #require(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
            Data(input.utf8) as CFData, nil)) as Data
        return input + "." + signature.base64URL
    }
}

private struct TestDERReader {
    let bytes: [UInt8]
    var index = 0
    mutating func read(tag: UInt8) throws -> [UInt8] {
        guard index + 2 <= bytes.count, bytes[index] == tag else { throw ChatGPTAuthError.invalidIdentity }
        index += 1
        var length = Int(bytes[index]); index += 1
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard (1...4).contains(count), index + count <= bytes.count else { throw ChatGPTAuthError.invalidIdentity }
            length = 0
            for _ in 0..<count { length = length * 256 + Int(bytes[index]); index += 1 }
        }
        guard index + length <= bytes.count else { throw ChatGPTAuthError.invalidIdentity }
        let result = Array(bytes[index..<(index + length)])
        index += length
        return result
    }
}
