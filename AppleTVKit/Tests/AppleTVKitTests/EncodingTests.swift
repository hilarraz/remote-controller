import Foundation
import Testing
@testable import AppleTVKit

@Suite struct OPACKTests {
    // Vectors taken from pyatv's OPACK test suite.
    @Test func encodesScalars() {
        #expect(OPACK.null.encoded() == Data([0x04]))
        #expect(OPACK.bool(true).encoded() == Data([0x01]))
        #expect(OPACK.bool(false).encoded() == Data([0x02]))
        #expect(OPACK.int(0).encoded() == Data([0x08]))
        #expect(OPACK.int(0x27).encoded() == Data([0x2F]))
        #expect(OPACK.int(0x28).encoded() == Data([0x30, 0x28]))
        #expect(OPACK.int(0x1FF).encoded() == Data([0x31, 0xFF, 0x01]))
        #expect(OPACK.int(0x1FFFFFF).encoded() == Data([0x32, 0xFF, 0xFF, 0xFF, 0x01]))
        #expect(OPACK.float(1.0).encoded() == Data([0x36, 0, 0, 0, 0, 0, 0, 0xF0, 0x3F]))
        #expect(OPACK.string("a").encoded() == Data([0x41, 0x61]))
        #expect(OPACK.data(Data([0xAC])).encoded() == Data([0x71, 0xAC]))
    }

    @Test func encodesLongValues() {
        let string = String(repeating: "a", count: 33)
        #expect(OPACK.string(string).encoded() == Data([0x61, 0x21]) + Data(string.utf8))
        let data = Data(repeating: 0x61, count: 256)
        #expect(OPACK.data(data).encoded() == Data([0x92, 0x00, 0x01]) + data)
    }

    @Test func encodesContainers() {
        #expect(OPACK.array([.int(1), .string("a")]).encoded() == Data([0xD2, 0x09, 0x41, 0x61]))
        #expect(OPACK.dict([(.string("a"), .bool(false))]).encoded() == Data([0xE1, 0x41, 0x61, 0x02]))
        let endless = OPACK.array(Array(repeating: .bool(true), count: 15))
        #expect(endless.encoded() == Data([0xDF]) + Data(repeating: 0x01, count: 15) + Data([0x03]))
    }

    @Test func roundTrips() throws {
        let value: OPACK = [
            "_i": "_systemInfo", "_t": 2, "_x": .int(40_000),
            "_c": ["name": "Mac", "_idsID": .data(Data(repeating: 1, count: 40)), "list": [1, 2, 3], "f": 0.5],
        ]
        #expect(try OPACK.decode(value.encoded()) == value)
    }

    @Test func decodesReferences() throws {
        // ["abc", "abc"] where the second item references the first object.
        let decoded = try OPACK.decode(Data([0xD2, 0x43, 0x61, 0x62, 0x63, 0xA0]))
        #expect(decoded == .array([.string("abc"), .string("abc")]))
    }
}

@Suite struct TLV8Tests {
    @Test func splitsLongValues() {
        let value = Data(repeating: 0xAB, count: 300)
        let encoded = TLV8.encode([(.publicKey, value), (.seqNo, Data([2]))])
        #expect(encoded.count == 2 + 255 + 2 + 45 + 3)
        let decoded = TLV8.decode(encoded)
        #expect(decoded[.publicKey] == value)
        #expect(decoded[.seqNo] == Data([2]))
    }
}

@Suite struct BinaryPlistTests {
    @Test func foundationReadsOurOutput() throws {
        let value: PlistValue = .dict([
            ("string", .string("héllo")),
            ("int", .int(100_000)),
            ("bool", .bool(true)),
            ("data", .data(Data([1, 2, 3]))),
            ("array", .array((0..<20).map { .int(Int64($0)) })),
        ])
        let data = BinaryPlist.encode(value)
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        #expect(parsed?["string"] as? String == "héllo")
        #expect(parsed?["int"] as? Int == 100_000)
        #expect(parsed?["bool"] as? Bool == true)
        #expect((parsed?["array"] as? [Int])?.count == 20)
        #expect(try BinaryPlist.decode(data) == value)
    }

    @Test func rtiPayloadIsAValidKeyedArchive() throws {
        let uuid = Data(repeating: 7, count: 16)
        let payload = KeyedArchive.rtiInputTextPayload(sessionUUID: uuid, text: "Bonjour")
        let parsed = try PropertyListSerialization.propertyList(from: payload, format: nil) as? [String: Any]
        #expect(parsed?["$archiver"] as? String == "RTIKeyedArchiver")
        #expect(KeyedArchive.property(in: payload, path: ["textOperations", "keyboardOutput", "insertionText"]) == .string("Bonjour"))
        #expect(KeyedArchive.property(in: payload, path: ["textOperations", "targetSessionUUID", "NS.uuidbytes"]) == .data(uuid))
    }
}
