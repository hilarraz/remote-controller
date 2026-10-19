import CryptoKit
import Foundation

/// Long-term keys obtained from pair-setup, needed for every later pair-verify.
public struct HAPCredentials: Codable, Sendable, Equatable {
    /// The accessory's long-term Ed25519 public key.
    public var ltpk: Data
    /// Our long-term Ed25519 private key (seed).
    public var ltsk: Data
    /// The accessory's pairing identifier.
    public var atvID: Data
    /// Our pairing identifier.
    public var clientID: Data

    public init(ltpk: Data, ltsk: Data, atvID: Data, clientID: Data) {
        self.ltpk = ltpk
        self.ltsk = ltsk
        self.atvID = atvID
        self.clientID = clientID
    }

    /// Same textual format as pyatv: four hex strings separated by colons.
    public var stringValue: String {
        [ltpk, ltsk, atvID, clientID].map(\.hexString).joined(separator: ":")
    }

    public init?(string: String) {
        let parts = string.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4,
              let ltpk = Data(hexString: parts[0]),
              let ltsk = Data(hexString: parts[1]),
              let atvID = Data(hexString: parts[2]),
              let clientID = Data(hexString: parts[3]) else { return nil }
        self.init(ltpk: ltpk, ltsk: ltsk, atvID: atvID, clientID: clientID)
    }
}

public enum PairingError: LocalizedError {
    case missingField(String)
    case deviceError(code: UInt8)
    case wrongPIN
    case badSignature
    case unexpectedDevice

    public var errorDescription: String? {
        switch self {
        case .missingField(let name): return "Réponse de jumelage incomplète (\(name))."
        case .deviceError(let code):
            switch code {
            case 0x02: return "Code PIN incorrect."
            case 0x03: return "Trop de tentatives, réessayez plus tard."
            case 0x04: return "L'Apple TV n'accepte plus de nouveaux appareils."
            case 0x05: return "Trop de tentatives échouées."
            case 0x06: return "Jumelage indisponible pour le moment."
            case 0x07: return "L'Apple TV est occupée par un autre jumelage."
            default: return "Erreur de jumelage (code \(code))."
            }
        case .wrongPIN: return "Code PIN incorrect."
        case .badSignature: return "Signature de l'Apple TV invalide."
        case .unexpectedDevice: return "L'appareil ne correspond pas au jumelage enregistré."
        }
    }
}

private func checkError(_ tlv: [UInt8: Data]) throws {
    if let error = tlv[.error], let code = error.first {
        throw PairingError.deviceError(code: code)
    }
}

/// HomeKit pair-setup (M1 to M6) with a PIN shown on the device.
final class HAPPairSetup {
    private let signingKey: Curve25519.Signing.PrivateKey
    private let pairingID: Data
    private var srp: SRPClient.Result?
    private var encryptionKey = Data()

    init() {
        signingKey = Curve25519.Signing.PrivateKey()
        pairingID = Data(UUID().uuidString.lowercased().utf8)
    }

    /// M1: start pairing (the device displays a PIN after receiving it).
    func startRequest() -> Data {
        TLV8.encode([(.method, Data([0x00])), (.seqNo, Data([0x01]))])
    }

    /// Handles M2 and builds M3.
    func proofRequest(m2: Data, pin: String) throws -> Data {
        let tlv = TLV8.decode(m2)
        try checkError(tlv)
        guard let salt = tlv[.salt] else { throw PairingError.missingField("salt") }
        guard let serverPublic = tlv[.publicKey] else { throw PairingError.missingField("public key") }

        let client = SRPClient(password: pin, privateKey: signingKey.rawRepresentation)
        let result = try client.process(salt: salt, serverPublicKey: serverPublic)
        srp = result
        return TLV8.encode([(.seqNo, Data([0x03])), (.publicKey, result.publicKey), (.proof, result.proof)])
    }

    /// Handles M4 and builds M5 (our long-term identity, encrypted).
    func exchangeRequest(m4: Data, name: String?) throws -> Data {
        let tlv = TLV8.decode(m4)
        if let error = tlv[.error], error.first == 0x02 { throw PairingError.wrongPIN }
        try checkError(tlv)
        guard let srp else { throw PairingError.missingField("srp") }
        guard let serverProof = tlv[.proof] else { throw PairingError.missingField("proof") }
        guard serverProof == srp.expectedServerProof else { throw PairingError.wrongPIN }

        let controllerX = CryptoHelpers.hkdf(
            salt: "Pair-Setup-Controller-Sign-Salt", info: "Pair-Setup-Controller-Sign-Info", secret: srp.sessionKey)
        encryptionKey = CryptoHelpers.hkdf(
            salt: "Pair-Setup-Encrypt-Salt", info: "Pair-Setup-Encrypt-Info", secret: srp.sessionKey)

        let publicKey = signingKey.publicKey.rawRepresentation
        let signature = try signingKey.signature(for: controllerX + pairingID + publicKey)

        var entries: [(TLV8.Tag, Data)] = [(.identifier, pairingID), (.publicKey, publicKey), (.signature, signature)]
        if let name {
            entries.append((.name, OPACK.dict([(.string("name"), .string(name))]).encoded()))
        }
        let encrypted = try CryptoHelpers.seal(
            TLV8.encode(entries), key: encryptionKey, nonce: CryptoHelpers.paddedNonce("PS-Msg05"))
        return TLV8.encode([(.seqNo, Data([0x05])), (.encryptedData, encrypted)])
    }

    /// Handles M6 and returns the resulting credentials.
    func finish(m6: Data) throws -> HAPCredentials {
        let tlv = TLV8.decode(m6)
        try checkError(tlv)
        guard let encrypted = tlv[.encryptedData] else { throw PairingError.missingField("encrypted data") }
        let decrypted = TLV8.decode(
            try CryptoHelpers.open(encrypted, key: encryptionKey, nonce: CryptoHelpers.paddedNonce("PS-Msg06")))
        // The device signature is not checked here (pyatv doesn't either): pair-verify
        // validates the device's long-term key on every connection anyway.
        guard let deviceID = decrypted[.identifier],
              let devicePublicKey = decrypted[.publicKey] else { throw PairingError.missingField("device info") }

        return HAPCredentials(
            ltpk: devicePublicKey,
            ltsk: signingKey.rawRepresentation,
            atvID: deviceID,
            clientID: pairingID
        )
    }
}

/// HomeKit pair-verify: proves both identities and derives a fresh shared secret.
final class HAPPairVerify {
    private let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
    private let credentials: HAPCredentials
    private(set) var sharedSecret = Data()

    init(credentials: HAPCredentials) {
        self.credentials = credentials
    }

    /// M1: our ephemeral public key.
    func startRequest() -> Data {
        TLV8.encode([(.seqNo, Data([0x01])), (.publicKey, ephemeralKey.publicKey.rawRepresentation)])
    }

    /// Handles M2 (device proof) and builds M3 (our proof).
    func finishRequest(m2: Data) throws -> Data {
        let tlv = TLV8.decode(m2)
        try checkError(tlv)
        guard let devicePublic = tlv[.publicKey] else { throw PairingError.missingField("public key") }
        guard let encrypted = tlv[.encryptedData] else { throw PairingError.missingField("encrypted data") }

        sharedSecret = try CryptoHelpers.x25519SharedSecret(ephemeralKey, peer: devicePublic)
        let sessionKey = CryptoHelpers.hkdf(
            salt: "Pair-Verify-Encrypt-Salt", info: "Pair-Verify-Encrypt-Info", secret: sharedSecret)

        let inner = TLV8.decode(
            try CryptoHelpers.open(encrypted, key: sessionKey, nonce: CryptoHelpers.paddedNonce("PV-Msg02")))
        guard let identifier = inner[.identifier], let signature = inner[.signature] else {
            throw PairingError.missingField("device identity")
        }
        guard identifier == credentials.atvID else { throw PairingError.unexpectedDevice }

        let deviceKey = try Curve25519.Signing.PublicKey(rawRepresentation: credentials.ltpk)
        guard deviceKey.isValidSignature(signature, for: devicePublic + identifier + ephemeralKey.publicKey.rawRepresentation) else {
            throw PairingError.badSignature
        }

        let ourPublic = ephemeralKey.publicKey.rawRepresentation
        let signingKey = try Curve25519.Signing.PrivateKey(rawRepresentation: credentials.ltsk)
        let ourSignature = try signingKey.signature(for: ourPublic + credentials.clientID + devicePublic)
        let payload = TLV8.encode([(.identifier, credentials.clientID), (.signature, ourSignature)])
        let sealed = try CryptoHelpers.seal(payload, key: sessionKey, nonce: CryptoHelpers.paddedNonce("PV-Msg03"))
        return TLV8.encode([(.seqNo, Data([0x03])), (.encryptedData, sealed)])
    }

    /// Checks M4 (an empty acknowledgement unless something failed).
    func finish(m4: Data) throws {
        try checkError(TLV8.decode(m4))
    }

    func deriveKey(salt: String, info: String) -> Data {
        CryptoHelpers.hkdf(salt: salt, info: info, secret: sharedSecret)
    }
}
