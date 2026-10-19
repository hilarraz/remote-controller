import Foundation

/// A value in Apple's OPACK serialization format (used by the Companion protocol).
public enum OPACK: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case float(Double)
    case string(String)
    case data(Data)
    case uuid(UUID)
    case date(Double)
    case array([OPACK])
    case dict([(OPACK, OPACK)])

    // MARK: Convenience accessors

    public subscript(key: String) -> OPACK? {
        guard case .dict(let pairs) = self else { return nil }
        return pairs.first { $0.0 == .string(key) }?.1
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int64? {
        switch self {
        case .int(let value): return value
        case .float(let value): return Int64(value)
        case .bool(let value): return value ? 1 : 0
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .float(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var dataValue: Data? {
        if case .data(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .int(let value): return value != 0
        default: return nil
        }
    }

    public var arrayValue: [OPACK]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var dictPairs: [(OPACK, OPACK)]? {
        if case .dict(let value) = self { return value }
        return nil
    }

    /// Dictionary entries whose keys are strings.
    public var stringKeyedDict: [String: OPACK]? {
        guard let pairs = dictPairs else { return nil }
        var result: [String: OPACK] = [:]
        for (key, value) in pairs {
            if let key = key.stringValue { result[key] = value }
        }
        return result
    }
}

extension OPACK: Equatable {
    public static func == (lhs: OPACK, rhs: OPACK) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case (.bool(let a), .bool(let b)): return a == b
        case (.int(let a), .int(let b)): return a == b
        case (.float(let a), .float(let b)): return a == b
        case (.string(let a), .string(let b)): return a == b
        case (.data(let a), .data(let b)): return a == b
        case (.uuid(let a), .uuid(let b)): return a == b
        case (.date(let a), .date(let b)): return a == b
        case (.array(let a), .array(let b)): return a == b
        case (.dict(let a), .dict(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
}

extension OPACK: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(floatLiteral value: Double) { self = .float(value) }
    public init(arrayLiteral elements: OPACK...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, OPACK)...) {
        self = .dict(elements.map { (.string($0.0), $0.1) })
    }
    public init(nilLiteral: ()) { self = .null }
}

extension OPACK: CustomStringConvertible {
    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .float(let value): return String(value)
        case .string(let value): return "\"\(value)\""
        case .data(let value): return "<\(value.count) bytes: \(value.prefix(48).hexString)>"
        case .uuid(let value): return value.uuidString
        case .date(let value): return "date(\(value))"
        case .array(let values): return "[" + values.map(\.description).joined(separator: ", ") + "]"
        case .dict(let pairs):
            return "{" + pairs.map { "\($0.0): \($0.1)" }.joined(separator: ", ") + "}"
        }
    }
}

public enum OPACKError: Error {
    case truncated
    case unsupportedType(UInt8)
    case invalidReference(Int)
    case invalidString
}

extension OPACK {
    // MARK: Encoding

    public func encoded() -> Data {
        var out = Data()
        encode(into: &out)
        return out
    }

    private func encode(into out: inout Data) {
        switch self {
        case .null:
            out.append(0x04)
        case .bool(let value):
            out.append(value ? 0x01 : 0x02)
        case .uuid(let value):
            out.append(0x05)
            out.append(contentsOf: value.bytes)
        case .date(let value):
            out.append(0x06)
            out.append(littleEndian: value.bitPattern)
        case .int(let value):
            if value >= 0 && value < 0x28 {
                out.append(UInt8(value) + 8)
            } else if value >= 0 && value <= 0xFF {
                out.append(0x30)
                out.append(UInt8(value))
            } else if value >= 0 && value <= 0xFFFF {
                out.append(0x31)
                out.append(littleEndian: UInt16(value))
            } else if value >= 0 && value <= 0xFFFF_FFFF {
                out.append(0x32)
                out.append(littleEndian: UInt32(value))
            } else {
                out.append(0x33)
                out.append(littleEndian: UInt64(bitPattern: value))
            }
        case .float(let value):
            out.append(0x36)
            out.append(littleEndian: value.bitPattern)
        case .string(let value):
            let bytes = Data(value.utf8)
            Self.appendSized(bytes, inlineBase: 0x40, sizedBase: 0x60, sizes: [1, 2, 3, 4], into: &out)
        case .data(let value):
            Self.appendSized(value, inlineBase: 0x70, sizedBase: 0x90, sizes: [1, 2, 4, 8], into: &out)
        case .array(let values):
            out.append(0xD0 + UInt8(min(values.count, 0xF)))
            for value in values { value.encode(into: &out) }
            if values.count >= 0xF { out.append(0x03) }
        case .dict(let pairs):
            out.append(0xE0 + UInt8(min(pairs.count, 0xF)))
            for (key, value) in pairs {
                key.encode(into: &out)
                value.encode(into: &out)
            }
            if pairs.count >= 0xF { out.append(0x03) }
        }
    }

    /// Strings and data are stored inline up to 32 bytes, otherwise with an explicit length.
    private static func appendSized(_ bytes: Data, inlineBase: UInt8, sizedBase: UInt8, sizes: [Int], into out: inout Data) {
        if bytes.count <= 0x20 {
            out.append(inlineBase + UInt8(bytes.count))
        } else {
            let index = sizes.firstIndex { bytes.count < (1 << (8 * $0)) } ?? sizes.count - 1
            out.append(sizedBase + UInt8(index + 1))
            var length = UInt64(bytes.count)
            for _ in 0..<sizes[index] {
                out.append(UInt8(length & 0xFF))
                length >>= 8
            }
        }
        out.append(bytes)
    }

    // MARK: Decoding

    public static func decode(_ data: Data) throws -> OPACK {
        var reader = OPACKReader(bytes: [UInt8](data))
        return try reader.read()
    }
}

private struct OPACKReader {
    let bytes: [UInt8]
    var pos = 0
    /// Previously decoded objects, which can be referenced later on in the stream.
    var objects: [OPACK] = []

    mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard pos + count <= bytes.count else { throw OPACKError.truncated }
        defer { pos += count }
        return bytes[pos..<pos + count]
    }

    mutating func readUInt(_ count: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for (shift, byte) in try take(count).enumerated() {
            value |= UInt64(byte) << (8 * UInt64(shift))
        }
        return value
    }

    mutating func read() throws -> OPACK {
        let tag = try take(1).first!
        var value: OPACK
        var remember = true

        switch tag {
        case 0x01: value = .bool(true); remember = false
        case 0x02: value = .bool(false); remember = false
        case 0x03: throw OPACKError.unsupportedType(tag)
        case 0x04: value = .null; remember = false
        case 0x05: value = .uuid(UUID(bytes: Array(try take(16))))
        case 0x06: value = .date(Double(bitPattern: try readUInt(8)))
        case 0x08...0x2F: value = .int(Int64(tag) - 8); remember = false
        case 0x30...0x33:
            let size = 1 << Int(tag & 0x0F)
            let raw = try readUInt(size)
            value = .int(size == 8 ? Int64(bitPattern: raw) : Int64(raw))
        case 0x35: value = .float(Double(Float(bitPattern: UInt32(try readUInt(4)))))
        case 0x36: value = .float(Double(bitPattern: try readUInt(8)))
        case 0x40...0x60:
            value = .string(try readString(Int(tag) - 0x40))
        case 0x61...0x64:
            let length = Int(try readUInt(Int(tag & 0x0F)))
            value = .string(try readString(length))
        case 0x70...0x90:
            value = .data(Data(try take(Int(tag) - 0x70)))
        case 0x91...0x94:
            let length = Int(try readUInt(1 << (Int(tag & 0x0F) - 1)))
            value = .data(Data(try take(length)))
        case 0xA0...0xC0:
            return try reference(Int(tag) - 0xA0)
        case 0xC1...0xC4:
            return try reference(Int(try readUInt(Int(tag) - 0xC0)))
        case 0xD0...0xDF:
            var items: [OPACK] = []
            if tag == 0xDF {
                while try peek() != 0x03 { items.append(try read()) }
                pos += 1
            } else {
                for _ in 0..<Int(tag & 0x0F) { items.append(try read()) }
            }
            value = .array(items)
            remember = false
        case 0xE0...0xEF:
            var pairs: [(OPACK, OPACK)] = []
            if tag == 0xEF {
                while try peek() != 0x03 { pairs.append((try read(), try read())) }
                pos += 1
            } else {
                for _ in 0..<Int(tag & 0x0F) { pairs.append((try read(), try read())) }
            }
            value = .dict(pairs)
            remember = false
        default:
            throw OPACKError.unsupportedType(tag)
        }

        if remember && !objects.contains(value) {
            objects.append(value)
        }
        return value
    }

    func peek() throws -> UInt8 {
        guard pos < bytes.count else { throw OPACKError.truncated }
        return bytes[pos]
    }

    mutating func readString(_ length: Int) throws -> String {
        guard let string = String(bytes: try take(length), encoding: .utf8) else { throw OPACKError.invalidString }
        return string
    }

    func reference(_ index: Int) throws -> OPACK {
        guard index < objects.count else { throw OPACKError.invalidReference(index) }
        return objects[index]
    }
}
