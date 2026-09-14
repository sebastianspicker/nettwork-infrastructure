import XCTest

@testable import NetworkModel

final class IPAMDomainTests: XCTestCase {
    func testStandardsCorrectAddressParsingAndCanonicalFormatting() throws {
        XCTAssertEqual(IPAddress(parsing: "192.0.2.1")?.description, "192.0.2.1")
        XCTAssertNil(IPAddress(parsing: "192.0.2.01"))
        XCTAssertNil(IPAddress(parsing: "256.0.2.1"))
        XCTAssertNil(IPAddress(parsing: "192.0.2"))
        XCTAssertEqual(IPAddress(parsing: "2001:0DB8:0:0:8:800:200C:417A")?.description, "2001:db8::8:800:200c:417a")
        XCTAssertEqual(IPAddress(parsing: "2001:db8:0:0:1:0:0:1")?.description, "2001:db8::1:0:0:1")
        XCTAssertEqual(IPAddress(parsing: "::ffff:192.0.2.1")?.description, "::ffff:c000:201")
        XCTAssertNil(IPAddress(parsing: "2001:::1"))
        XCTAssertNil(IPAddress(parsing: "2001:db8::1::1"))
        XCTAssertNil(IPAddress(parsing: "fe80::1%en0"))
    }

    func testPrefixBoundsReservationsAndUtilization() throws {
        let vrf = VRF(name: "production")
        let reserved = try XCTUnwrap(
            ReservedAddressRange(
                lowerBound: try XCTUnwrap(IPAddress(parsing: "192.0.2.1")),
                upperBound: try XCTUnwrap(IPAddress(parsing: "192.0.2.1"))
            ))
        let prefix = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "192.0.2.3/30", reservedRanges: [reserved]))
        XCTAssertEqual(prefix.cidr, "192.0.2.0/30")
        XCTAssertEqual(prefix.lowerBound.description, "192.0.2.0")
        XCTAssertEqual(prefix.upperBound.description, "192.0.2.3")
        XCTAssertTrue(prefix.contains(try XCTUnwrap(IPAddress(parsing: "192.0.2.2"))))
        XCTAssertFalse(prefix.contains(try XCTUnwrap(IPAddress(parsing: "192.0.2.4"))))
        XCTAssertTrue(prefix.isReserved(try XCTUnwrap(IPAddress(parsing: "192.0.2.1"))))
        let allocation = IPAddressRecord(vrfID: vrf.id, address: try XCTUnwrap(IPAddress(parsing: "192.0.2.2")))
        let utilization = prefix.utilization(addresses: [allocation])
        XCTAssertEqual(utilization.capacityExponent, 2)
        XCTAssertEqual(utilization.reservedFraction, 0.25)
        XCTAssertEqual(utilization.allocatedFraction, 0.25)
        XCTAssertEqual(utilization.consumedFraction, 0.5)
        let reservedAddress = IPAddressRecord(vrfID: vrf.id, address: try XCTUnwrap(IPAddress(parsing: "192.0.2.1")))
        XCTAssertThrowsError(try DefaultIPAMValidationService.validate(prefixes: [prefix], addresses: [reservedAddress], vlans: []))
    }

    func testNestedPrefixesAndRevisionCompareAndSwap() throws {
        let vrf = VRF(name: "production", revision: 4)
        let parent = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "2001:db8::/32"))
        let child = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "2001:db8:1::/48"))
        let result = try PrefixLayoutMutation.apply(prefixes: [parent, child], to: vrf, expectedRevision: 4)
        XCTAssertEqual(result.vrf.revision, 5)
        XCTAssertThrowsError(try PrefixLayoutMutation.apply(prefixes: [parent], to: vrf, expectedRevision: 3)) { error in
            XCTAssertEqual(error as? IPAMValidationError, .revisionConflict(vrfID: vrf.id, expected: 3, actual: 4))
        }
        let duplicate = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "2001:db8::/32"))
        XCTAssertThrowsError(try DefaultIPAMValidationService.validate(prefixes: [parent, duplicate], addresses: [], vlans: []))
    }

    func testDeterministicAddressNameAndExplicitReassignmentLifecycle() throws {
        let vrf = VRF(name: "production")
        let parsed = try XCTUnwrap(IPAddress(parsing: "2001:0db8::1"))
        let address = IPAddressRecord(vrfID: vrf.id, address: parsed)
        XCTAssertEqual(address.id, IPAddressRecord.deterministicRecordName(vrfID: vrf.id, address: try XCTUnwrap(IPAddress(parsing: "2001:db8:0:0:0:0:0:1"))))

        let oldInterface = Interface(deviceID: ObjectID(), physicalPortID: ObjectID(), name: "Gi0/1", mode: .routed)
        let newInterface = Interface(deviceID: ObjectID(), physicalPortID: ObjectID(), name: "Gi0/2", mode: .routed)
        var assigned = address
        assigned.assignedInterfaceID = oldInterface.id
        let oldAssignment = IPAddressAssignment(addressID: assigned.id, interfaceID: oldInterface.id, isPrimary: true)
        let result = try IPAMAddressLifecycle.reassign(address: assigned, assignments: [oldAssignment], to: newInterface)
        XCTAssertEqual(result.address.assignedInterfaceID, newInterface.id)
        XCTAssertTrue(result.assignments.contains { $0.interfaceID == oldInterface.id && !$0.isActive })
        XCTAssertTrue(result.assignments.contains { $0.interfaceID == newInterface.id && $0.isActive && $0.isPrimary })
    }

    func testInterfaceAssignmentAndVLANRules() throws {
        let vrf = VRF(name: "production")
        let prefix = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "10.0.0.0/24"))
        let group = VLANGroup(name: "campus")
        let users = VLAN(groupID: group.id, number: 100, name: "users")
        let servers = VLAN(groupID: group.id, number: 200, name: "servers")
        let access = Interface(deviceID: ObjectID(), physicalPortID: ObjectID(), name: "Gi0/1", mode: .access)
        let trunk = Interface(deviceID: ObjectID(), physicalPortID: ObjectID(), name: "Gi0/2", mode: .trunk)
        let routed = Interface(deviceID: ObjectID(), physicalPortID: ObjectID(), name: "Gi0/3", mode: .routed)
        let loopback = Interface(deviceID: ObjectID(), name: "Lo0", mode: .routed, kind: .loopback)
        let vlanInterface = Interface(deviceID: ObjectID(), name: "Vlan100", mode: .routed, kind: .vlan, vlanID: users.id)
        var address = IPAddressRecord(vrfID: vrf.id, address: try XCTUnwrap(IPAddress(parsing: "10.0.0.10")))
        address.assignedInterfaceID = routed.id
        let assignment = IPAddressAssignment(addressID: address.id, interfaceID: routed.id, isPrimary: true)
        let memberships = [
            InterfaceVLANMembership(interfaceID: access.id, vlanID: users.id, isNative: true),
            InterfaceVLANMembership(interfaceID: trunk.id, vlanID: users.id, isNative: true),
            InterfaceVLANMembership(interfaceID: trunk.id, vlanID: servers.id),
        ]
        try DefaultIPAMValidationService.validate(
            prefixes: [prefix], addresses: [address], vlans: [users, servers],
            interfaces: [access, trunk, routed, loopback, vlanInterface], assignments: [assignment], memberships: memberships
        )

        let invalidAccessMembership = InterfaceVLANMembership(interfaceID: access.id, vlanID: users.id)
        XCTAssertThrowsError(
            try DefaultIPAMValidationService.validate(
                prefixes: [prefix], addresses: [address], vlans: [users, servers],
                interfaces: [access, trunk, routed, loopback, vlanInterface], assignments: [assignment],
                memberships: [invalidAccessMembership, memberships[1], memberships[2]]
            ))
        XCTAssertThrowsError(
            try DefaultIPAMValidationService.validate(
                prefixes: [prefix], addresses: [], vlans: [users, VLAN(groupID: group.id, number: 100, name: "duplicate")]))
    }

    func testTombstonedRecordsCannotBeReferencedByActiveAssignments() throws {
        let vrf = VRF(name: "production")
        let prefix = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "10.0.0.0/24"))
        let interface = Interface(deviceID: ObjectID(), physicalPortID: ObjectID(), name: "Gi0/1", mode: .routed)
        var address = IPAddressRecord(vrfID: vrf.id, address: try XCTUnwrap(IPAddress(parsing: "10.0.0.10")))
        address.tombstone()
        let assignment = IPAddressAssignment(addressID: address.id, interfaceID: interface.id, isPrimary: true)
        XCTAssertThrowsError(
            try DefaultIPAMValidationService.validate(
                prefixes: [prefix], addresses: [address], vlans: [], interfaces: [interface], assignments: [assignment], memberships: []
            )
        ) { error in
            XCTAssertEqual(error as? IPAMValidationError, .missingAddressAssignment(address.id))
        }
    }
}
