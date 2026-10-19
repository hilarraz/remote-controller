import Foundation

/// Helpers for the NSKeyedArchiver payloads exchanged by the remote text input (RTI) service.
public enum KeyedArchive {
    /// Follows `path` from `$top`, resolving UID references along the way.
    public static func property(in archive: Data, path: [String]) -> PlistValue? {
        guard let root = try? BinaryPlist.decode(archive),
              let objects = root["$objects"]?.arrayValue,
              var element = root["$top"] else { return nil }
        element = resolve(element, objects)
        for key in path {
            guard let next = element[key] else { return nil }
            element = resolve(next, objects)
        }
        return element
    }

    private static func resolve(_ value: PlistValue, _ objects: [PlistValue]) -> PlistValue {
        if let uid = value.uidValue, Int(uid) < objects.count {
            return objects[Int(uid)]
        }
        return value
    }

    private static func classInfo(_ name: String) -> PlistValue {
        .dict([("$classname", .string(name)), ("$classes", .array([.string(name), .string("NSObject")]))])
    }

    private static func archive(_ objects: [PlistValue]) -> Data {
        BinaryPlist.encode(.dict([
            ("$version", .int(100_000)),
            ("$archiver", .string("RTIKeyedArchiver")),
            ("$top", .dict([("textOperations", .uid(1))])),
            ("$objects", .array(objects)),
        ]))
    }

    /// Payload replacing the whole text of the focused field with an empty string.
    public static func rtiClearTextPayload(sessionUUID: Data) -> Data {
        archive([
            .string("$null"),
            .dict([
                ("$class", .uid(7)),
                ("targetSessionUUID", .uid(5)),
                ("keyboardOutput", .uid(2)),
                ("textToAssert", .uid(4)),
            ]),
            .dict([("$class", .uid(3))]),
            classInfo("TIKeyboardOutput"),
            .string(""),
            .dict([("NS.uuidbytes", .data(sessionUUID)), ("$class", .uid(6))]),
            classInfo("NSUUID"),
            classInfo("RTITextOperations"),
        ])
    }

    /// Payload inserting `text` at the cursor of the focused field.
    public static func rtiInputTextPayload(sessionUUID: Data, text: String) -> Data {
        archive([
            .string("$null"),
            .dict([
                ("keyboardOutput", .uid(2)),
                ("$class", .uid(7)),
                ("targetSessionUUID", .uid(5)),
            ]),
            .dict([("insertionText", .uid(3)), ("$class", .uid(4))]),
            .string(text),
            classInfo("TIKeyboardOutput"),
            .dict([("NS.uuidbytes", .data(sessionUUID)), ("$class", .uid(6))]),
            classInfo("NSUUID"),
            classInfo("RTITextOperations"),
        ])
    }
}
