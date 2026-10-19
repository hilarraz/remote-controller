import BigInt
import CryptoKit
import Foundation

/// SRP-6a client as used by HomeKit pair-setup (3072-bit group, SHA-512).
///
/// Integer-to-bytes conversions follow srptools (what pyatv uses): minimal big-endian
/// encoding everywhere, except `k` and `u` which use values padded to the prime's size.
struct SRPClient {
    static let prime = BigUInt(
        "FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA6"
            + "3B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245"
            + "E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F2411"
            + "7C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F"
            + "83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08"
            + "CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9"
            + "DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D"
            + "04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7"
            + "ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D8760273"
            + "3EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB31"
            + "43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF",
        radix: 16
    )!
    static let generator = BigUInt(5)
    static let username = "Pair-Setup"

    struct Result {
        /// Client public value A.
        let publicKey: Data
        /// Client proof M1.
        let proof: Data
        /// Shared session key K.
        let sessionKey: Data
        /// Proof the server must answer with (M2).
        let expectedServerProof: Data
    }

    enum SRPError: Error {
        case invalidServerPublicKey
    }

    let password: String
    let privateValue: BigUInt
    let publicValue: BigUInt

    init(password: String, privateKey: Data) {
        self.password = password
        self.privateValue = BigUInt(privateKey)
        self.publicValue = Self.generator.power(privateValue, modulus: Self.prime)
    }

    func process(salt: Data, serverPublicKey: Data) throws -> Result {
        let N = Self.prime
        let g = Self.generator
        let B = BigUInt(serverPublicKey)
        guard B % N != 0 else { throw SRPError.invalidServerPublicKey }
        let A = publicValue

        let k = BigUInt(Self.hash(Self.bytes(N), Self.pad(g)))
        let u = BigUInt(Self.hash(Self.pad(A), Self.pad(B)))
        let innerHash = Self.hash(Data("\(Self.username):\(password)".utf8))
        let x = BigUInt(Self.hash(salt, innerHash))
        let v = g.power(x, modulus: N)

        // S = (B - k * v) ^ (a + u * x) mod N
        let kv = (k * v) % N
        let base = (B % N + N - kv) % N
        let S = base.power(privateValue + u * x, modulus: N)
        let K = Self.hash(Self.bytes(S))

        let hN = BigUInt(Self.hash(Self.bytes(N)))
        let hg = BigUInt(Self.hash(Self.bytes(g)))
        let M1 = Self.hash(
            Self.bytes(hN ^ hg),
            Self.hash(Data(Self.username.utf8)),
            salt,
            Self.bytes(A),
            Self.bytes(B),
            K
        )
        let M2 = Self.hash(Self.bytes(A), M1, K)
        return Result(publicKey: Self.bytes(A), proof: M1, sessionKey: K, expectedServerProof: M2)
    }

    static func hash(_ parts: Data...) -> Data {
        var hasher = SHA512()
        for part in parts { hasher.update(data: part) }
        return Data(hasher.finalize())
    }

    /// Minimal big-endian representation (at least one byte).
    static func bytes(_ value: BigUInt) -> Data {
        let data = value.serialize()
        return data.isEmpty ? Data([0]) : data
    }

    static func pad(_ value: BigUInt) -> Data {
        let data = bytes(value)
        let width = prime.serialize().count
        return Data(repeating: 0, count: max(0, width - data.count)) + data
    }
}
