import Foundation

/// The one canonical JSON codec for persisted, mirrored, transferred, and
/// remote payloads: millisecond dates, sorted keys, and unescaped slashes.
/// Changing an option changes stored bytes and breaks exact-byte readers.
public enum CanonicalJSONCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}
