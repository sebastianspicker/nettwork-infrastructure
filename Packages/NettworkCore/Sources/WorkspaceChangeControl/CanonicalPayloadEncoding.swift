import Foundation

extension Date {
    /// The value this date decodes to after one round trip through the
    /// millisecond payload codecs. Immutable payloads are validated by
    /// decode-equality, so every timestamp stored in them must already be a
    /// fixed point of `.millisecondsSince1970`. The wire format is unchanged.
    public var canonicalPayloadTimestamp: Date {
        Date(timeIntervalSince1970: (1_000.0 * timeIntervalSince1970) / 1_000.0)
    }

    /// The current time, already representable by the payload codecs.
    public static var canonicalNow: Date { Date.now.canonicalPayloadTimestamp }
}

extension KeyedEncodingContainer {
    /// Encodes a set as the same JSON array shape as synthesized `Codable`,
    /// but in sorted order so canonical bytes do not depend on hash iteration.
    mutating func encodeSorted<Element: Encodable & Comparable>(_ set: Set<Element>, forKey key: Key) throws {
        try encode(set.sorted(), forKey: key)
    }
}
