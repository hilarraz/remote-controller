import Foundation

/// TLV8 encoding used by the HomeKit (HAP) pairing procedures.
public enum TLV8 {
    public enum Tag: UInt8 {
        case method = 0x00
        case identifier = 0x01
        case salt = 0x02
        case publicKey = 0x03
        case proof = 0x04
        case encryptedData = 0x05
        case seqNo = 0x06
        case error = 0x07
        case backOff = 0x08
        case certificate = 0x09
        case signature = 0x0A
        case permissions = 0x0B
        case fragmentData = 0x0C
        case fragmentLast = 0x0D
        case name = 0x11
        case flags = 0x13
    }

    /// Encodes entries in order, splitting values longer than 255 bytes into consecutive chunks.
    public static func encode(_ entries: [(Tag, Data)]) -> Data {
        var out = Data()
        for (tag, value) in entries {
            if value.isEmpty {
                out.append(tag.rawValue)
                out.append(0)
                continue
            }
            var offset = value.startIndex
            while offset < value.endIndex {
                let size = min(255, value.endIndex - offset)
                out.append(tag.rawValue)
                out.append(UInt8(size))
                out.append(value[offset..<offset + size])
                offset += size
            }
        }
        return out
    }

    /// Decodes TLV8 data, concatenating values for repeated tags.
    public static func decode(_ data: Data) -> [UInt8: Data] {
        var result: [UInt8: Data] = [:]
        let bytes = [UInt8](data)
        var pos = 0
        while pos + 2 <= bytes.count {
            let tag = bytes[pos]
            let length = Int(bytes[pos + 1])
            let end = min(pos + 2 + length, bytes.count)
            result[tag, default: Data()].append(contentsOf: bytes[(pos + 2)..<end])
            pos = end
        }
        return result
    }
}

extension Dictionary where Key == UInt8, Value == Data {
    subscript(tag: TLV8.Tag) -> Data? {
        self[tag.rawValue]
    }
}
