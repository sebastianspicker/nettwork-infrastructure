import Foundation

public enum IPAddress: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    case v4(UInt32)
    case v6([UInt16])

    /// Parses unambiguous dotted-decimal IPv4 and RFC 4291 IPv6 notation.
    public init?(parsing value: String) {
        guard !value.isEmpty, value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if value.contains(":") {
            guard let words = Self.parseV6(value) else { return nil }
            self = .v6(words)
        } else {
            guard let number = Self.parseV4(value) else { return nil }
            self = .v4(number)
        }
    }

    public var bitWidth: Int {
        switch self {
        case .v4: 32
        case .v6: 128
        }
    }
    var isWellFormed: Bool {
        if case .v6(let words) = self { return words.count == 8 }
        return true
    }

    /// RFC 5952 canonical IPv6 text: lowercase and the leftmost longest zero run.
    public var description: String {
        switch self {
        case .v4(let value):
            return [24, 16, 8, 0].map { String((value >> UInt32($0)) & 255) }.joined(separator: ".")
        case .v6(let words):
            return Self.canonicalV6(words)
        }
    }

    public static func < (lhs: IPAddress, rhs: IPAddress) -> Bool {
        switch (lhs, rhs) {
        case (.v4(let lhsValue), .v4(let rhsValue)): lhsValue < rhsValue
        case (.v6(let lhsWords), .v6(let rhsWords)): lhsWords.lexicographicallyPrecedes(rhsWords)
        case (.v4, .v6): true
        case (.v6, .v4): false
        }
    }

    func masked(prefixLength: Int) -> IPAddress {
        switch self {
        case .v4(let value):
            let mask: UInt32 = prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - prefixLength)
            return .v4(value & mask)
        case .v6(let words):
            var remaining = prefixLength
            return .v6(
                words.map { word in
                    defer { remaining -= 16 }
                    if remaining >= 16 { return word }
                    if remaining <= 0 { return 0 }
                    return word & (UInt16.max << UInt16(16 - remaining))
                })
        }
    }

    func upperBound(prefixLength: Int) -> IPAddress {
        switch masked(prefixLength: prefixLength) {
        case .v4(let value):
            let mask: UInt32 = prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - prefixLength)
            return .v4(value | ~mask)
        case .v6(let words):
            var remaining = prefixLength
            return .v6(
                words.map { word in
                    defer { remaining -= 16 }
                    if remaining >= 16 { return word }
                    if remaining <= 0 { return UInt16.max }
                    return word | ~(UInt16.max << UInt16(16 - remaining))
                })
        }
    }

    var ordinal: Double {
        switch self {
        case .v4(let value): Double(value)
        case .v6(let words): words.reduce(0) { $0 * 65_536 + Double($1) }
        }
    }

    private static func parseV4(_ input: String) -> UInt32? {
        let octets = input.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var result: UInt32 = 0
        for octet in octets {
            guard !octet.isEmpty,
                octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                !(octet.count > 1 && octet.first == "0"),
                let value = UInt16(octet), value <= 255
            else { return nil }
            result = (result << 8) | UInt32(value)
        }
        return result
    }

    private static func parseV6(_ input: String) -> [UInt16]? {
        guard !input.contains("%") else { return nil }
        let halves = input.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        guard let left = v6Tokens(halves[0]),
            let right = halves.count == 2 ? v6Tokens(halves[1]) : []
        else { return nil }
        guard let parsed = parseV6Groups(left + right, leftTokenCount: left.count) else { return nil }
        if halves.count == 1 { return parsed.words.count == 8 ? parsed.words : nil }
        let zeroCount = 8 - parsed.words.count
        guard zeroCount >= 1 else { return nil }
        return Array(parsed.words.prefix(parsed.leftWordCount)) + Array(repeating: 0, count: zeroCount) + Array(parsed.words.dropFirst(parsed.leftWordCount))
    }

    private static func v6Tokens(_ value: String) -> [Substring]? {
        guard !value.isEmpty else { return [] }
        let result = value.split(separator: ":", omittingEmptySubsequences: false)
        return result.contains(where: \.isEmpty) ? nil : result
    }

    private static func parseV6Groups(_ groups: [Substring], leftTokenCount: Int) -> (words: [UInt16], leftWordCount: Int)? {
        var words = [UInt16]()
        var leftWordCount = 0
        for (index, group) in groups.enumerated() {
            guard let parsed = parseV6Group(group, isLast: index == groups.count - 1) else { return nil }
            words.append(contentsOf: parsed)
            if index < leftTokenCount { leftWordCount += parsed.count }
        }
        return (words, leftWordCount)
    }

    private static func parseV6Group(_ group: Substring, isLast: Bool) -> [UInt16]? {
        if group.contains(".") {
            guard isLast, let v4 = parseV4(String(group)) else { return nil }
            return [UInt16((v4 >> 16) & 0xffff), UInt16(v4 & 0xffff)]
        }
        guard (1...4).contains(group.count),
            group.allSatisfy({ $0.isASCII && $0.isHexDigit }),
            let word = UInt16(group, radix: 16)
        else { return nil }
        return [word]
    }

    private static func canonicalV6(_ words: [UInt16]) -> String {
        guard !words.isEmpty else { return "" }
        guard let run = longestZeroRun(in: words), run.length >= 2 else {
            return words.map { String($0, radix: 16) }.joined(separator: ":")
        }
        let end = run.start + run.length
        let head = words[..<run.start].map { String($0, radix: 16) }.joined(separator: ":")
        let tail = words[end...].map { String($0, radix: 16) }.joined(separator: ":")
        if head.isEmpty && tail.isEmpty { return "::" }
        if head.isEmpty { return "::\(tail)" }
        if tail.isEmpty { return "\(head)::" }
        return "\(head)::\(tail)"
    }

    private static func longestZeroRun(in words: [UInt16]) -> (start: Int, length: Int)? {
        var best: (start: Int, length: Int)?
        var cursor = 0
        while cursor < words.count {
            guard words[cursor] == 0 else {
                cursor += 1
                continue
            }
            let start = cursor
            while cursor < words.count, words[cursor] == 0 { cursor += 1 }
            let candidate = (start, cursor - start)
            if (best?.length ?? 0) < candidate.1 { best = candidate }
        }
        return best
    }
}
