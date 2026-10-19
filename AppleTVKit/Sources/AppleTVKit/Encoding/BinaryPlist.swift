import Foundation

/// A property list value, including the UID type used by NSKeyedArchiver.
///
/// Foundation's PropertyListSerialization cannot create UIDs, so this module carries
/// its own minimal binary plist reader and writer.
public indirect enum PlistValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case real(Double)
    case date(Double)
    case data(Data)
    case string(String)
    case uid(UInt64)
    case array([PlistValue])
    case dict([(String, PlistValue)])

    public static func == (lhs: PlistValue, rhs: PlistValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.real(let a), .real(let b)): return a == b
        case (.date(let a), .date(let b)): return a == b
        case (.data(let a), .data(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.uid(let a), .uid(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.dict(let a), .dict(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> PlistValue? {
        guard case .dict(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }

    public subscript(index: Int) -> PlistValue? {
        guard case .array(let values) = self, values.indices.contains(index) else { return nil }
        return values[index]
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var dataValue: Data? {
        if case .data(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .real(let value): return Int64(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .real(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        default: return nil
        }
    }

    public var arrayValue: [PlistValue]? {
        if case .array(let values) = self { return values }
        return nil
    }

    public var uidValue: UInt64? {
        if case .uid(let value) = self { return value }
        return nil
    }
}

public enum BinaryPlistError: Error {
    case invalidHeader
    case truncated
    case unsupportedMarker(UInt8)
    case invalidKey
}

public enum BinaryPlist {
    // MARK: Writing

    public static func encode(_ root: PlistValue) -> Data {
        var objects: [PlistValue] = []
        var refs: [[Int]] = []

        // Flatten the tree: every value becomes an object; containers keep child indices.
        func flatten(_ value: PlistValue) -> Int {
            let index = objects.count
            objects.append(value)
            refs.append([])
            switch value {
            case .array(let items):
                refs[index] = items.map(flatten)
            case .dict(let pairs):
                let keys = pairs.map { flatten(.string($0.0)) }
                let values = pairs.map { flatten($0.1) }
                refs[index] = keys + values
            default:
                break
            }
            return index
        }
        _ = flatten(root)

        let refSize = byteWidth(for: UInt64(objects.count))

        var out = Data("bplist00".utf8)
        var offsets: [Int] = []
        for (index, value) in objects.enumerated() {
            offsets.append(out.count)
            out.append(serialize(value, refs: refs[index], refSize: refSize))
        }

        let offsetTableOffset = out.count
        let offsetSize = byteWidth(for: UInt64(offsetTableOffset))
        for offset in offsets {
            appendBigEndian(UInt64(offset), width: offsetSize, to: &out)
        }

        out.append(contentsOf: [0, 0, 0, 0, 0, 0])
        out.append(UInt8(offsetSize))
        out.append(UInt8(refSize))
        out.append(bigEndian: UInt64(objects.count))
        out.append(bigEndian: UInt64(0))
        out.append(bigEndian: UInt64(offsetTableOffset))
        return out
    }

    private static func serialize(_ value: PlistValue, refs: [Int], refSize: Int) -> Data {
        var out = Data()
        switch value {
        case .null:
            out.append(0x00)
        case .bool(let flag):
            out.append(flag ? 0x09 : 0x08)
        case .int(let number):
            if number < 0 {
                out.append(0x13)
                out.append(bigEndian: UInt64(bitPattern: number))
            } else {
                let width = byteWidth(for: UInt64(number))
                out.append(0x10 | UInt8(width.trailingZeroBitCount))
                appendBigEndian(UInt64(number), width: width, to: &out)
            }
        case .real(let number):
            out.append(0x23)
            out.append(bigEndian: number.bitPattern)
        case .date(let seconds):
            out.append(0x33)
            out.append(bigEndian: seconds.bitPattern)
        case .data(let bytes):
            appendMarker(0x40, count: bytes.count, to: &out)
            out.append(bytes)
        case .string(let string):
            if string.allSatisfy(\.isASCII) {
                let bytes = Data(string.utf8)
                appendMarker(0x50, count: bytes.count, to: &out)
                out.append(bytes)
            } else {
                let units = Array(string.utf16)
                appendMarker(0x60, count: units.count, to: &out)
                for unit in units { out.append(bigEndian: unit) }
            }
        case .uid(let uid):
            let width = byteWidth(for: uid)
            out.append(0x80 | UInt8(width - 1))
            appendBigEndian(uid, width: width, to: &out)
        case .array:
            appendMarker(0xA0, count: refs.count, to: &out)
            for ref in refs { appendBigEndian(UInt64(ref), width: refSize, to: &out) }
        case .dict:
            appendMarker(0xD0, count: refs.count / 2, to: &out)
            for ref in refs { appendBigEndian(UInt64(ref), width: refSize, to: &out) }
        }
        return out
    }

    private static func appendMarker(_ marker: UInt8, count: Int, to out: inout Data) {
        if count < 15 {
            out.append(marker | UInt8(count))
        } else {
            out.append(marker | 0x0F)
            let width = byteWidth(for: UInt64(count))
            out.append(0x10 | UInt8(width.trailingZeroBitCount))
            appendBigEndian(UInt64(count), width: width, to: &out)
        }
    }

    private static func byteWidth(for value: UInt64) -> Int {
        if value <= 0xFF { return 1 }
        if value <= 0xFFFF { return 2 }
        if value <= 0xFFFF_FFFF { return 4 }
        return 8
    }

    private static func appendBigEndian(_ value: UInt64, width: Int, to out: inout Data) {
        for shift in stride(from: (width - 1) * 8, through: 0, by: -8) {
            out.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    // MARK: Reading

    public static func decode(_ data: Data) throws -> PlistValue {
        let bytes = Data(data)
        guard bytes.count >= 40, bytes.prefix(6) == Data("bplist".utf8) else { throw BinaryPlistError.invalidHeader }
        let trailer = bytes.count - 32
        let offsetSize = Int(bytes[trailer + 6])
        let refSize = Int(bytes[trailer + 7])
        let objectCount = Int(bytes.readBigEndian(at: trailer + 8, count: 8))
        let topObject = Int(bytes.readBigEndian(at: trailer + 16, count: 8))
        let offsetTable = Int(bytes.readBigEndian(at: trailer + 24, count: 8))
        guard offsetTable + objectCount * offsetSize <= trailer else { throw BinaryPlistError.truncated }

        let offsets = (0..<objectCount).map { Int(bytes.readBigEndian(at: offsetTable + $0 * offsetSize, count: offsetSize)) }

        func readCount(_ marker: UInt8, at offset: inout Int) throws -> Int {
            let low = Int(marker & 0x0F)
            if low != 0x0F { return low }
            let intMarker = bytes[offset]
            guard intMarker & 0xF0 == 0x10 else { throw BinaryPlistError.unsupportedMarker(intMarker) }
            let width = 1 << Int(intMarker & 0x0F)
            let count = Int(bytes.readBigEndian(at: offset + 1, count: width))
            offset += 1 + width
            return count
        }

        func object(_ index: Int, depth: Int) throws -> PlistValue {
            guard index < offsets.count, depth < 64 else { throw BinaryPlistError.truncated }
            var offset = offsets[index]
            guard offset < trailer else { throw BinaryPlistError.truncated }
            let marker = bytes[offset]
            offset += 1
            switch marker >> 4 {
            case 0x0:
                switch marker {
                case 0x08: return .bool(false)
                case 0x09: return .bool(true)
                default: return .null
                }
            case 0x1:
                let width = 1 << Int(marker & 0x0F)
                let raw = bytes.readBigEndian(at: offset, count: min(width, 8))
                return .int(width >= 8 ? Int64(bitPattern: raw) : Int64(raw))
            case 0x2:
                let width = 1 << Int(marker & 0x0F)
                let raw = bytes.readBigEndian(at: offset, count: width)
                return .real(width == 4 ? Double(Float(bitPattern: UInt32(raw))) : Double(bitPattern: raw))
            case 0x3:
                return .date(Double(bitPattern: bytes.readBigEndian(at: offset, count: 8)))
            case 0x4:
                let count = try readCount(marker, at: &offset)
                return .data(bytes.subdata(in: offset..<offset + count))
            case 0x5:
                let count = try readCount(marker, at: &offset)
                return .string(String(decoding: bytes.subdata(in: offset..<offset + count), as: UTF8.self))
            case 0x6:
                let count = try readCount(marker, at: &offset)
                let units = (0..<count).map { UInt16(bytes.readBigEndian(at: offset + $0 * 2, count: 2)) }
                return .string(String(decoding: units, as: UTF16.self))
            case 0x8:
                return .uid(bytes.readBigEndian(at: offset, count: Int(marker & 0x0F) + 1))
            case 0xA:
                let count = try readCount(marker, at: &offset)
                return .array(try (0..<count).map {
                    try object(Int(bytes.readBigEndian(at: offset + $0 * refSize, count: refSize)), depth: depth + 1)
                })
            case 0xD:
                let count = try readCount(marker, at: &offset)
                var pairs: [(String, PlistValue)] = []
                for i in 0..<count {
                    let keyRef = Int(bytes.readBigEndian(at: offset + i * refSize, count: refSize))
                    let valueRef = Int(bytes.readBigEndian(at: offset + (count + i) * refSize, count: refSize))
                    guard let key = try object(keyRef, depth: depth + 1).stringValue else { throw BinaryPlistError.invalidKey }
                    pairs.append((key, try object(valueRef, depth: depth + 1)))
                }
                return .dict(pairs)
            default:
                throw BinaryPlistError.unsupportedMarker(marker)
            }
        }

        return try object(topObject, depth: 0)
    }
}
