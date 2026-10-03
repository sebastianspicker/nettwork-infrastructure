import Foundation

public enum IPAMRecordState: String, Codable, Hashable, Sendable { case active, tombstoned }

public struct ReservedAddressRange: Codable, Hashable, Sendable {
    public var lowerBound: IPAddress
    public var upperBound: IPAddress
    public init?(lowerBound: IPAddress, upperBound: IPAddress) {
        guard lowerBound.isWellFormed, upperBound.isWellFormed,
            lowerBound.bitWidth == upperBound.bitWidth, lowerBound <= upperBound
        else { return nil }
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
    public func contains(_ address: IPAddress) -> Bool {
        address.bitWidth == lowerBound.bitWidth && lowerBound <= address && address <= upperBound
    }
    public func overlaps(_ other: ReservedAddressRange) -> Bool {
        lowerBound.bitWidth == other.lowerBound.bitWidth && lowerBound <= other.upperBound && other.lowerBound <= upperBound
    }
}

public struct PrefixUtilization: Codable, Hashable, Sendable {
    /// The capacity is exactly 2 raised to this exponent, so IPv6 /0 cannot overflow.
    public var capacityExponent: Int
    public var allocatedAddressCount: Int
    public var reservedFraction: Double
    public init(capacityExponent: Int, allocatedAddressCount: Int, reservedFraction: Double) {
        self.capacityExponent = capacityExponent
        self.allocatedAddressCount = allocatedAddressCount
        self.reservedFraction = reservedFraction
    }
    public var allocatedFraction: Double { Double(allocatedAddressCount) / pow(2, Double(capacityExponent)) }
    public var consumedFraction: Double { min(1, reservedFraction + allocatedFraction) }
}

public struct Prefix: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var vrfID: ObjectID
    public var network: IPAddress
    public var prefixLength: Int
    public var name: String
    public var reservedRanges: [ReservedAddressRange]
    public var state: IPAMRecordState
    public var tombstonedAt: Date?

    public init?(
        id: ObjectID = .init(), vrfID: ObjectID, cidr: String, name: String = "", reservedRanges: [ReservedAddressRange] = [], state: IPAMRecordState = .active,
        tombstonedAt: Date? = nil
    ) {
        let pieces = cidr.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, let address = IPAddress(parsing: String(pieces[0])), let length = Int(pieces[1]), String(length) == String(pieces[1]),
            (0...address.bitWidth).contains(length)
        else { return nil }
        self.id = id
        self.vrfID = vrfID
        self.network = address.masked(prefixLength: length)
        self.prefixLength = length
        self.name = name
        self.reservedRanges = reservedRanges
        self.state = state
        self.tombstonedAt = tombstonedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, vrfID, network, prefixLength, name, reservedRanges, state, tombstonedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let network = try container.decode(IPAddress.self, forKey: .network)
        let prefixLength = try container.decode(Int.self, forKey: .prefixLength)
        let reservedRanges = try container.decode([ReservedAddressRange].self, forKey: .reservedRanges)
        guard Self.isCanonicalNetwork(network, prefixLength: prefixLength) else {
            throw DecodingError.dataCorruptedError(
                forKey: .prefixLength,
                in: container,
                debugDescription: "Prefix length and network address must form a canonical CIDR."
            )
        }
        guard Self.rangesAreContained(reservedRanges, network: network, prefixLength: prefixLength) else {
            throw DecodingError.dataCorruptedError(
                forKey: .reservedRanges,
                in: container,
                debugDescription: "Reserved ranges must be canonical and contained by the prefix."
            )
        }
        guard Self.rangesDoNotOverlap(reservedRanges) else {
            throw DecodingError.dataCorruptedError(
                forKey: .reservedRanges,
                in: container,
                debugDescription: "Reserved ranges must not overlap."
            )
        }
        id = try container.decode(ObjectID.self, forKey: .id)
        vrfID = try container.decode(ObjectID.self, forKey: .vrfID)
        self.network = network
        self.prefixLength = prefixLength
        name = try container.decode(String.self, forKey: .name)
        self.reservedRanges = reservedRanges
        state = try container.decode(IPAMRecordState.self, forKey: .state)
        tombstonedAt = try container.decodeIfPresent(Date.self, forKey: .tombstonedAt)
    }

    private static func isCanonicalNetwork(_ network: IPAddress, prefixLength: Int) -> Bool {
        network.isWellFormed
            && (0...network.bitWidth).contains(prefixLength)
            && network.masked(prefixLength: prefixLength) == network
    }

    private static func rangesAreContained(
        _ ranges: [ReservedAddressRange], network: IPAddress, prefixLength: Int
    ) -> Bool {
        let upperBound = network.upperBound(prefixLength: prefixLength)
        return ranges.allSatisfy { range in
            range.lowerBound.isWellFormed && range.upperBound.isWellFormed
                && range.lowerBound.bitWidth == network.bitWidth
                && range.upperBound.bitWidth == network.bitWidth
                && network <= range.lowerBound && range.lowerBound <= range.upperBound
                && range.upperBound <= upperBound
        }
    }

    private static func rangesDoNotOverlap(_ ranges: [ReservedAddressRange]) -> Bool {
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        return !sorted.indices.dropLast().contains { sorted[$0].overlaps(sorted[$0 + 1]) }
    }
    public var cidr: String { "\(network)/\(prefixLength)" }
    public var lowerBound: IPAddress { network }
    public var upperBound: IPAddress { network.upperBound(prefixLength: prefixLength) }
    public var addressCapacityExponent: Int { network.bitWidth - prefixLength }
    public var isActive: Bool { state == .active }
    public func contains(_ address: IPAddress) -> Bool {
        address.isWellFormed && address.bitWidth == network.bitWidth && address.masked(prefixLength: prefixLength) == network
    }
    public func contains(_ other: Prefix) -> Bool {
        vrfID == other.vrfID && network.bitWidth == other.network.bitWidth && prefixLength <= other.prefixLength && contains(other.network)
    }
    public func contains(_ range: ReservedAddressRange) -> Bool { contains(range.lowerBound) && contains(range.upperBound) }
    public func isReserved(_ address: IPAddress) -> Bool { reservedRanges.contains { $0.contains(address) } }
    public func utilization(addresses: [IPAddressRecord]) -> PrefixUtilization {
        let allocated = Set(addresses.lazy.filter { $0.isActive && contains($0.address) && !isReserved($0.address) }.map(\.address)).count
        let capacity = pow(2, Double(addressCapacityExponent))
        let reserved = mergedReservedRanges().reduce(0.0) { total, range in
            total + (range.upperBound.ordinal - range.lowerBound.ordinal + 1) / capacity
        }
        return PrefixUtilization(capacityExponent: addressCapacityExponent, allocatedAddressCount: allocated, reservedFraction: min(1, reserved))
    }
    public mutating func tombstone(at date: Date = .now) {
        state = .tombstoned
        tombstonedAt = date
    }
    public mutating func reactivate() throws {
        guard state == .tombstoned else { throw IPAMLifecycleError.recordAlreadyActive(id.description) }
        state = .active
        tombstonedAt = nil
    }
    private func mergedReservedRanges() -> [ReservedAddressRange] {
        reservedRanges.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { result, range in
            guard let previous = result.last, previous.overlaps(range) else {
                result.append(range)
                return
            }
            guard let merged = ReservedAddressRange(lowerBound: previous.lowerBound, upperBound: max(previous.upperBound, range.upperBound)) else {
                preconditionFailure("Overlapping validated ranges must produce a valid merged range.")
            }
            result[result.count - 1] = merged
        }
    }
}

public struct VRF: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var name: String
    public var revision: Int
    public var state: IPAMRecordState
    public var tombstonedAt: Date?
    public init(id: ObjectID = .init(), name: String, revision: Int = 0, state: IPAMRecordState = .active, tombstonedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.revision = max(0, revision)
        self.state = state
        self.tombstonedAt = tombstonedAt
    }
    public var isActive: Bool { state == .active }
}

public struct PrefixLayoutMutationResult: Codable, Hashable, Sendable {
    public var vrf: VRF
    public var prefixes: [Prefix]
    public init(vrf: VRF, prefixes: [Prefix]) {
        self.vrf = vrf
        self.prefixes = prefixes
    }
}

/// `expectedRevision` is the mandatory compare-and-swap token for the complete VRF layout.
public enum PrefixLayoutMutation {
    public static func apply(prefixes: [Prefix], to vrf: VRF, expectedRevision: Int) throws -> PrefixLayoutMutationResult {
        guard vrf.isActive else { throw IPAMLifecycleError.tombstonedRecord(vrf.id.description) }
        guard expectedRevision == vrf.revision else {
            throw IPAMValidationError.revisionConflict(vrfID: vrf.id, expected: expectedRevision, actual: vrf.revision)
        }
        guard prefixes.allSatisfy({ $0.vrfID == vrf.id }) else { throw IPAMValidationError.crossVRFPrefixMutation(vrf.id) }
        guard vrf.revision < Int.max else { throw IPAMValidationError.revisionOverflow(vrf.id) }
        try DefaultIPAMValidationService.validate(prefixes: prefixes, addresses: [], vlans: [])
        var nextVRF = vrf
        nextVRF.revision += 1
        return PrefixLayoutMutationResult(vrf: nextVRF, prefixes: prefixes)
    }
}
