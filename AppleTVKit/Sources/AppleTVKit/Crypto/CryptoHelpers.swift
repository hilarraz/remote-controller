import CryptoKit
import Foundation

enum CryptoHelpers {
    /// HKDF-SHA512 producing a 32-byte key, as used throughout HAP.
    static func hkdf(salt: String, info: String, secret: Data) -> Data {
        hkdf(salt: Data(salt.utf8), info: Data(info.utf8), secret: secret)
    }

    static func hkdf(salt: Data, info: Data, secret: Data) -> Data {
        let key = HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: salt,
            info: info,
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// Seals with ChaCha20-Poly1305 and returns ciphertext followed by the 16-byte tag.
    static func seal(_ plaintext: Data, key: Data, nonce: Data, aad: Data = Data()) throws -> Data {
        let box = try ChaChaPoly.seal(
            plaintext,
            using: SymmetricKey(data: key),
            nonce: try ChaChaPoly.Nonce(data: nonce),
            authenticating: aad
        )
        return box.ciphertext + box.tag
    }

    static func open(_ sealed: Data, key: Data, nonce: Data, aad: Data = Data()) throws -> Data {
        guard sealed.count >= 16 else { throw CryptoKitError.authenticationFailure }
        let box = try ChaChaPoly.SealedBox(
            nonce: try ChaChaPoly.Nonce(data: nonce),
            ciphertext: sealed.prefix(sealed.count - 16),
            tag: sealed.suffix(16)
        )
        return try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: aad)
    }

    /// A short ASCII nonce such as "PV-Msg02", left-padded with zeros to 12 bytes.
    static func paddedNonce(_ label: String) -> Data {
        let bytes = Data(label.utf8)
        return Data(repeating: 0, count: 12 - bytes.count) + bytes
    }

    static func x25519SharedSecret(_ privateKey: Curve25519.KeyAgreement.PrivateKey, peer: Data) throws -> Data {
        let peerKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer)
        let secret = try privateKey.sharedSecretFromKeyAgreement(with: peerKey)
        return secret.withUnsafeBytes { Data($0) }
    }
}

/// Counter-based ChaCha20-Poly1305 transport encryption.
struct ChaChaStream {
    enum NonceLayout {
        /// 12-byte little-endian counter (Companion).
        case counter12
        /// Four zero bytes followed by an 8-byte little-endian counter (HAP / AirPlay).
        case zeroPaddedCounter8
    }

    let outputKey: Data
    let inputKey: Data
    let layout: NonceLayout
    private(set) var outputCounter: UInt64 = 0
    private(set) var inputCounter: UInt64 = 0

    init(outputKey: Data, inputKey: Data, layout: NonceLayout) {
        self.outputKey = outputKey
        self.inputKey = inputKey
        self.layout = layout
    }

    private func nonce(_ counter: UInt64) -> Data {
        var nonce = Data()
        switch layout {
        case .counter12:
            nonce.append(littleEndian: counter)
            nonce.append(contentsOf: [0, 0, 0, 0])
        case .zeroPaddedCounter8:
            nonce.append(contentsOf: [0, 0, 0, 0])
            nonce.append(littleEndian: counter)
        }
        return nonce
    }

    mutating func encrypt(_ data: Data, aad: Data = Data()) throws -> Data {
        defer { outputCounter += 1 }
        return try CryptoHelpers.seal(data, key: outputKey, nonce: nonce(outputCounter), aad: aad)
    }

    mutating func decrypt(_ data: Data, aad: Data = Data()) throws -> Data {
        defer { inputCounter += 1 }
        return try CryptoHelpers.open(data, key: inputKey, nonce: nonce(inputCounter), aad: aad)
    }
}
