import Foundation

extension Data {
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    public init?(hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(chars.count / 2)
        var index = 0
        while index < chars.count {
            guard let high = Self.nibble(chars[index]), let low = Self.nibble(chars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    private static func nibble(_ char: UInt8) -> UInt8? {
        switch char {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return char - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return char - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return char - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    mutating func append<T: FixedWidthInteger>(littleEndian value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func append<T: FixedWidthInteger>(bigEndian value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    /// Reads an unsigned big-endian integer of `count` bytes starting at `offset`.
    func readBigEndian(at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<count {
            value = value << 8 | UInt64(self[startIndex + offset + i])
        }
        return value
    }

    /// Reads an unsigned little-endian integer of `count` bytes starting at `offset`.
    func readLittleEndian(at offset: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<count {
            value |= UInt64(self[startIndex + offset + i]) << (8 * UInt64(i))
        }
        return value
    }

    static func random(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) })
    }
}

extension UUID {
    init(bytes: [UInt8]) {
        precondition(bytes.count == 16)
        self.init(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                         bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    var bytes: [UInt8] {
        withUnsafeBytes(of: uuid) { Array($0) }
    }
}
