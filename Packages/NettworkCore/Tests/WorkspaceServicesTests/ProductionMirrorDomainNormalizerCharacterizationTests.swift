import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Pins the mirror normalization contract (ProductionMirrorDomainNormalizer
/// doc comment): legacy aggregates are migration seeds only, every direct
/// record save or tombstone overlays that seed, record identity must match the
/// resource key, and malformed or ambiguous input fails the whole projection.
/// Also pins `MirrorProjection`'s typed IPAM/audit decoding on top of it.
final class ProductionMirrorDomainNormalizerCharacterizationTests: XCTestCase {
    private let topology = TopologyFixture()
    private let namespace = ServiceFixture.namespace()

    func testDirectRecordsOverlayTheLegacyAggregateSeed() throws {
        var renamed = topology.panelDevice
        renamed.name = "Panel renamed"
        let aggregate = PhysicalTopology(deviceTypes: [topology.switchType, topology.panelType], devices: [topology.switchDevice, topology.panelDevice])
        let records = [
            try ServiceFixture.mirror(aggregate, key: .string("legacy-topology"), type: "NettworkPhysicalTopology", namespace: namespace),
            try ServiceFixture.mirror(renamed, type: "NettworkDevice", namespace: namespace, tag: "renamed"),
        ]

        let projection = try ProductionMirrorDomainProjection(records: records)

        XCTAssertEqual(projection.topology.devices.map(\.id), [topology.switchDevice.id, topology.panelDevice.id])
        XCTAssertEqual(projection.topology.devices.map(\.name), [topology.switchDevice.name, "Panel renamed"])
        XCTAssertEqual(projection.topology.deviceTypes.count, 2)
    }

    func testDirectTombstoneRemovesTheSeededRecord() throws {
        let aggregate = PhysicalTopology(deviceTypes: [topology.switchType, topology.panelType], devices: [topology.switchDevice, topology.panelDevice])
        let tombstone = LocalMirrorRecord(
            namespace: namespace, resourceKey: .object(topology.panelDevice.id), recordType: "NettworkDevice", schemaVersion: 1, payload: nil,
            systemFields: nil, changeTag: nil, isTombstone: true, serverModifiedAt: ServiceFixture.epoch, verifiedAt: ServiceFixture.epoch)

        let projection = try ProductionMirrorDomainProjection(records: [
            try ServiceFixture.mirror(aggregate, key: .string("legacy-topology"), type: "NettworkPhysicalTopology", namespace: namespace), tombstone,
        ])

        XCTAssertEqual(projection.topology.devices.map(\.id), [topology.switchDevice.id])
    }

    func testRecordIdentityMustMatchItsResourceKey() throws {
        let wrongKey = ResourceKey.object(ObjectID())
        let record = try ServiceFixture.mirror(topology.switchDevice, key: wrongKey, type: "NettworkDevice", namespace: namespace)

        XCTAssertThrowsError(try ProductionMirrorDomainProjection(records: [record])) { error in
            XCTAssertEqual(error as? ProductionMirrorDomainNormalizationError, .resourceKeyMismatch(wrongKey))
        }
    }

    func testMalformedPayloadFailsTheWholeProjection() throws {
        let key = ResourceKey.object(topology.switchDevice.id)
        let record = try ServiceFixture.mirror(["unexpected": true], key: key, type: "NettworkDevice", namespace: namespace)

        XCTAssertThrowsError(try ProductionMirrorDomainProjection(records: [record])) { error in
            XCTAssertEqual(error as? ProductionMirrorDomainNormalizationError, .malformedRecord(key))
        }
    }

    func testAmbiguousHierarchyAggregatesAreRejected() throws {
        let hierarchy = WorkspaceHierarchy(locations: HierarchyFixture().locations)
        let records = [
            try ServiceFixture.mirror(hierarchy, key: .string("hierarchy-a"), type: "NettworkWorkspaceHierarchy", namespace: namespace),
            try ServiceFixture.mirror(hierarchy, key: .string("hierarchy-b"), type: "WorkspaceHierarchy", namespace: namespace),
        ]

        XCTAssertThrowsError(try ProductionMirrorDomainProjection(records: records)) { error in
            guard case .ambiguousAggregate? = error as? ProductionMirrorDomainNormalizationError else {
                return XCTFail("Expected ambiguousAggregate, got \(error)")
            }
        }
    }

    func testPlacementStateWithoutAHierarchyIsIncomplete() throws {
        let anchor = FloorPlanAnchor(objectID: topology.switchDevice.id, floorID: ObjectID(), x: 0.5, y: 0.5)
        let records = try topology.records(in: namespace) + [try ServiceFixture.mirror(anchor, type: "NettworkFloorPlanAnchor", namespace: namespace)]

        XCTAssertThrowsError(try ProductionMirrorDomainProjection(records: records)) { error in
            XCTAssertEqual(error as? ProductionMirrorDomainNormalizationError, .incompletePlacementProjection)
        }
    }

    func testMirrorProjectionDecodesLiveIPAMRecordsAndSkipsTombstones() throws {
        let ipam = IPAMFixture(deviceID: topology.switchDevice.id)
        var retired = ipam.otherAddress
        retired.tombstone(at: ServiceFixture.epoch)
        let tombstonedVRF = LocalMirrorRecord(
            namespace: namespace, resourceKey: .object(ObjectID()), recordType: "NettworkVRF", schemaVersion: 1, payload: nil, systemFields: nil,
            changeTag: nil, isTombstone: true, serverModifiedAt: ServiceFixture.epoch, verifiedAt: ServiceFixture.epoch)
        let legacyPrefix = Prefix(vrfID: ipam.vrf.id, cidr: "198.51.100.0/24").unsafelyUnwrappedForFixture
        let records =
            try topology.records(in: namespace) + ipam.records(in: namespace).filter { $0.resourceKey != .string(retired.id) } + [
                try ServiceFixture.mirror(retired, key: .string(retired.id), type: "NettworkIPAddressRecord", namespace: namespace),
                try ServiceFixture.mirror(legacyPrefix, type: LocalRecordKind.prefix, namespace: namespace), tombstonedVRF,
            ]

        let projection = try MirrorProjection(records: records, conflicts: [], conflictResourceKeys: [], conflictCount: 0, syncState: nil)

        XCTAssertEqual(projection.vrfs.map(\.id), [ipam.vrf.id])
        XCTAssertEqual(Set(projection.prefixes.map(\.id)), [ipam.prefix.id, legacyPrefix.id])
        XCTAssertEqual(Set(projection.addresses.map(\.id)), [ipam.address.id, retired.id])
        XCTAssertEqual(projection.addresses.first { $0.id == retired.id }?.isActive, false)
        XCTAssertEqual(projection.interfaces.map(\.id), [ipam.interface.id])
    }

    func testMirrorProjectionRejectsAnIPAMRecordUnderAnotherIdentity() throws {
        let ipam = IPAMFixture(deviceID: topology.switchDevice.id)
        let wrongKey = ResourceKey.string("ip:somewhere-else")
        let record = try ServiceFixture.mirror(ipam.address, key: wrongKey, type: "NettworkIPAddressRecord", namespace: namespace)

        XCTAssertThrowsError(try MirrorProjection(records: [record], conflicts: [], conflictResourceKeys: [], conflictCount: 0, syncState: nil)) { error in
            guard case let ProductionAdapterError.mirrorRecordIdentityMismatch(key, type)? = error as? ProductionAdapterError else {
                return XCTFail("Expected mirrorRecordIdentityMismatch, got \(error)")
            }
            XCTAssertEqual(key, wrongKey)
            XCTAssertEqual(type, "NettworkIPAddressRecord")
        }
    }
}
