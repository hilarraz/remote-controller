import Foundation

/// Minimal protocol buffers support: just enough to build and read the MediaRemote
/// messages we use, without generated code.
struct ProtoWriter {
    private(set) var data = Data()

    static func varint(_ value: UInt64) -> Data {
        var value = value
        var out = Data()
        while value >= 0x80 {
            out.append(UInt8(value & 0x7F) | 0x80)
            value >>= 7
        }
        out.append(UInt8(value))
        return out
    }

    private mutating func key(_ field: Int, _ wireType: UInt64) {
        data.append(Self.varint(UInt64(field) << 3 | wireType))
    }

    mutating func uint(_ field: Int, _ value: UInt64) {
        key(field, 0)
        data.append(Self.varint(value))
    }

    mutating func int(_ field: Int, _ value: Int64) {
        uint(field, UInt64(bitPattern: value))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        uint(field, value ? 1 : 0)
    }

    mutating func double(_ field: Int, _ value: Double) {
        key(field, 1)
        data.append(littleEndian: value.bitPattern)
    }

    mutating func bytes(_ field: Int, _ value: Data) {
        key(field, 2)
        data.append(Self.varint(UInt64(value.count)))
        data.append(value)
    }

    mutating func string(_ field: Int, _ value: String) {
        bytes(field, Data(value.utf8))
    }

    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var inner = ProtoWriter()
        build(&inner)
        bytes(field, inner.data)
    }
}

/// A decoded message: every field number maps to the values seen, in order.
struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case fixed64(UInt64)
        case fixed32(UInt32)
        case bytes(Data)
    }

    private(set) var fields: [Int: [Value]] = [:]

    init() {}

    init?(_ data: Data) {
        let bytes = [UInt8](data)
        var pos = 0

        func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            while pos < bytes.count, shift < 64 {
                let byte = bytes[pos]
                pos += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        while pos < bytes.count {
            guard let key = readVarint() else { return nil }
            let field = Int(key >> 3)
            let value: Value
            switch key & 0x7 {
            case 0:
                guard let number = readVarint() else { return nil }
                value = .varint(number)
            case 1:
                guard pos + 8 <= bytes.count else { return nil }
                value = .fixed64(Data(bytes[pos..<pos + 8]).readLittleEndian(at: 0, count: 8))
                pos += 8
            case 2:
                guard let length = readVarint(), pos + Int(length) <= bytes.count else { return nil }
                value = .bytes(Data(bytes[pos..<pos + Int(length)]))
                pos += Int(length)
            case 5:
                guard pos + 4 <= bytes.count else { return nil }
                value = .fixed32(UInt32(Data(bytes[pos..<pos + 4]).readLittleEndian(at: 0, count: 4)))
                pos += 4
            default:
                return nil
            }
            fields[field, default: []].append(value)
        }
    }

    /// Fields of `other` replace ours (like protobuf's MergeFrom for scalar fields).
    mutating func merge(_ other: ProtoMessage) {
        for (field, values) in other.fields {
            fields[field] = values
        }
    }

    func has(_ field: Int) -> Bool { fields[field] != nil }

    func uint(_ field: Int) -> UInt64? {
        if case .varint(let value) = fields[field]?.last { return value }
        return nil
    }

    func int(_ field: Int) -> Int64? {
        uint(field).map { Int64(bitPattern: $0) }
    }

    func bool(_ field: Int) -> Bool? {
        uint(field).map { $0 != 0 }
    }

    func double(_ field: Int) -> Double? {
        if case .fixed64(let raw) = fields[field]?.last { return Double(bitPattern: raw) }
        return nil
    }

    func float(_ field: Int) -> Float? {
        if case .fixed32(let raw) = fields[field]?.last { return Float(bitPattern: raw) }
        return nil
    }

    func bytes(_ field: Int) -> Data? {
        if case .bytes(let value) = fields[field]?.last { return value }
        return nil
    }

    func string(_ field: Int) -> String? {
        bytes(field).flatMap { String(data: $0, encoding: .utf8) }
    }

    func message(_ field: Int) -> ProtoMessage? {
        bytes(field).flatMap(ProtoMessage.init)
    }

    func messages(_ field: Int) -> [ProtoMessage] {
        (fields[field] ?? []).compactMap { value in
            if case .bytes(let data) = value { return ProtoMessage(data) }
            return nil
        }
    }
}
