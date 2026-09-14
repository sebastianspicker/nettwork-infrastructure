import Foundation
import XCTest

@testable import NetworkModel

final class IPAMValidationIndexTests: XCTestCase {
    func testIndexedValidationMatchesLegacyOracleForFixedSeeds() throws {
        for seed in [UInt64(1), 42, 0xC0FFEE, 0xDEADBEEF] {
            var generator = FixedGenerator(seed: seed)
            let fixture = makeFixture(generator: &generator, count: 240)
            XCTAssertEqual(validationError(for: fixture), legacyValidationError(for: fixture), "seed \(seed)")
        }
    }

    func testAncestorReservationsApplyAcrossIPv4AndIPv6WhileTombstonesDoNot() throws {
        let vrf = VRF(name: "mixed")
        let v4Reserved = try XCTUnwrap(
            ReservedAddressRange(lowerBound: IPAddress(parsing: "10.0.1.8")!, upperBound: IPAddress(parsing: "10.0.1.8")!))
        let v6Reserved = try XCTUnwrap(
            ReservedAddressRange(lowerBound: IPAddress(parsing: "2001:db8:1::8")!, upperBound: IPAddress(parsing: "2001:db8:1::8")!))
        let v4Parent = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "10.0.0.0/16", reservedRanges: [v4Reserved]))
        let v4Child = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "10.0.1.0/24"))
        let v6Parent = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "2001:db8::/32", reservedRanges: [v6Reserved]))
        let v6Child = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "2001:db8:1::/48"))

        for value in ["10.0.1.8", "2001:db8:1::8"] {
            let address = IPAddressRecord(vrfID: vrf.id, address: IPAddress(parsing: value)!)
            XCTAssertThrowsError(
                try DefaultIPAMValidationService.validate(
                    prefixes: [v4Parent, v4Child, v6Parent, v6Child],
                    addresses: [address],
                    vlans: []
                )
            ) { error in
                XCTAssertEqual(error as? IPAMValidationError, .addressReserved(address.id))
            }
        }

        var tombstonedParent = v6Parent
        tombstonedParent.tombstone()
        let address = IPAddressRecord(vrfID: vrf.id, address: IPAddress(parsing: "2001:db8:1::8")!)
        XCTAssertNoThrow(
            try DefaultIPAMValidationService.validate(
                prefixes: [tombstonedParent, v6Child],
                addresses: [address],
                vlans: []
            ))
    }

    func testEarliestDuplicatePairAndIndividualErrorPrecedenceArePreserved() throws {
        let vrf = VRF(name: "production")
        let first = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "10.0.0.0/24"))
        let intervening = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "10.1.0.0/24"))
        let interveningDuplicate = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "10.1.0.0/24"))
        let firstDuplicate = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "10.0.0.0/24"))

        XCTAssertThrowsError(
            try DefaultIPAMValidationService.validate(
                prefixes: [first, intervening, interveningDuplicate, firstDuplicate],
                addresses: [],
                vlans: []
            )
        ) { error in
            XCTAssertEqual(error as? IPAMValidationError, .duplicatePrefix(first, firstDuplicate))
        }

        let malformed = try malformedPrefix(from: first)
        XCTAssertThrowsError(
            try DefaultIPAMValidationService.validate(prefixes: [malformed, first, firstDuplicate], addresses: [], vlans: [])
        ) { error in
            XCTAssertEqual(error as? IPAMValidationError, .invalidPrefix(malformed.id))
        }
    }

    func testIndexedValidationScalesAcrossThousandsOfPrefixesAndAddresses() throws {
        let vrf = VRF(name: "scale")
        let prefixes = (0..<4_000).map { offset in
            Prefix(vrfID: vrf.id, cidr: IPAddress.v4(UInt32(offset)).description + "/32")!
        }
        let addresses = (0..<4_000).map { offset in
            IPAddressRecord(vrfID: vrf.id, address: .v4(UInt32(offset)))
        }
        XCTAssertNoThrow(try DefaultIPAMValidationService.validate(prefixes: prefixes, addresses: addresses, vlans: []))
    }

    private func validationError(for fixture: (prefixes: [Prefix], addresses: [IPAddressRecord])) -> IPAMValidationError? {
        do {
            try DefaultIPAMValidationService.validate(prefixes: fixture.prefixes, addresses: fixture.addresses, vlans: [])
            return nil
        } catch {
            return error as? IPAMValidationError
        }
    }

    private func legacyValidationError(for fixture: (prefixes: [Prefix], addresses: [IPAddressRecord])) -> IPAMValidationError? {
        do {
            try LegacyIPAMValidationOracle.validate(prefixes: fixture.prefixes, addresses: fixture.addresses)
            return nil
        } catch {
            return error as? IPAMValidationError
        }
    }

    private func makeFixture(generator: inout FixedGenerator, count: Int) -> (prefixes: [Prefix], addresses: [IPAddressRecord]) {
        let vrf = VRF(name: "seeded")
        var prefixes = (0..<count).map { offset in
            Prefix(vrfID: vrf.id, cidr: IPAddress.v4(UInt32(offset) << 8).description + "/24")!
        }
        if generator.next().isMultiple(of: 2) {
            prefixes.append(prefixes[Int(generator.next() % UInt64(prefixes.count))])
        }
        let addresses = (0..<count).map { offset in
            IPAddressRecord(vrfID: vrf.id, address: .v4((UInt32(offset) << 8) | UInt32(generator.next() % 254 + 1)))
        }
        return (prefixes, addresses)
    }

    private func malformedPrefix(from prefix: Prefix) throws -> Prefix {
        let data = try JSONEncoder().encode(prefix)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["prefixLength"] = 33
        return try JSONDecoder().decode(Prefix.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

private enum LegacyIPAMValidationOracle {
    static func validate(prefixes: [Prefix], addresses: [IPAddressRecord]) throws {
        let active = prefixes.filter(\.isActive)
        try validatePrefixes(active)
        try validateAddresses(addresses, activePrefixes: active)
    }

    private static func validatePrefixes(_ active: [Prefix]) throws {
        for prefix in active { try validate(prefix) }
        for (offset, prefix) in active.dropLast().enumerated() {
            for other in active.dropFirst(offset + 1) where prefix.vrfID == other.vrfID && prefix.network.bitWidth == other.network.bitWidth {
                if prefix.network == other.network, prefix.prefixLength == other.prefixLength {
                    throw IPAMValidationError.duplicatePrefix(prefix, other)
                }
            }
        }
    }

    private static func validateAddresses(_ addresses: [IPAddressRecord], activePrefixes: [Prefix]) throws {
        var names = Set<String>()
        for address in addresses {
            guard names.insert(address.id).inserted,
                address.address.isWellFormed,
                address.id == IPAddressRecord.deterministicRecordName(vrfID: address.vrfID, address: address.address)
            else { throw IPAMValidationError.duplicateAddress(address.id) }
            let containing = activePrefixes.filter { $0.vrfID == address.vrfID && $0.contains(address.address) }
            guard !address.isActive || !containing.isEmpty else { throw IPAMValidationError.addressOutsidePrefixes(address.id) }
            guard !address.isActive || !containing.contains(where: { $0.isReserved(address.address) }) else {
                throw IPAMValidationError.addressReserved(address.id)
            }
        }
    }

    private static func validate(_ prefix: Prefix) throws {
        guard prefix.network.isWellFormed,
            (0...prefix.network.bitWidth).contains(prefix.prefixLength),
            prefix.network.masked(prefixLength: prefix.prefixLength) == prefix.network
        else { throw IPAMValidationError.invalidPrefix(prefix.id) }
        for range in prefix.reservedRanges where !prefix.contains(range) {
            throw IPAMValidationError.invalidReservedRange(prefixID: prefix.id)
        }
        let ranges = prefix.reservedRanges.sorted { $0.lowerBound < $1.lowerBound }
        for index in ranges.indices.dropLast() where ranges[index].overlaps(ranges[index + 1]) {
            throw IPAMValidationError.overlappingReservedRange(prefixID: prefix.id)
        }
    }
}

private struct FixedGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
