import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Pins the planner contract: it plans against the lease-gated mirror, binds
/// every save/tombstone to the exact mirrored system fields (or
/// `.mustNotExist` for new records), carries the workspace sentinel as a
/// read-only dependency, and rejects drafts that violate domain invariants.
final class SwiftDataProductionMutationPlannerCharacterizationTests: XCTestCase {
    private let topology = TopologyFixture()
    private let completedAt = ServiceFixture.epoch.addingTimeInterval(3_600)

    // MARK: Topology

    func testConnectPlansOneNewCableAndBindsTheWorkspaceSentinel() async throws {
        let (planner, namespace) = try await makePlanner(topology.records(in: ServiceFixture.namespace()))
        let cable = topology.patch()

        let material = try await planner.materializeCompletion(of: order([.topology(.connect(.init(cable: cable)))]), at: completedAt, in: namespace)

        XCTAssertEqual(material.saves.map(\.resourceKey), [.object(cable.id)])
        XCTAssertEqual(material.saves.first?.recordType, "Cable")
        XCTAssertEqual(try decode(Cable.self, material.saves.first?.encodedRecord), cable)
        XCTAssertTrue(material.tombstones.isEmpty)
        XCTAssertEqual(material.touchedPreconditions, [.object(cable.id): .mustNotExist(.object(cable.id))])
        XCTAssertEqual(material.readOnlyDependencies.map(\.resourceKey), [ServiceFixture.sentinelKey(namespace)])
        XCTAssertEqual(material.readOnlyDependencies.first?.precondition, ServiceFixture.exact("workspace-active"))
        let issues = try await planner.issues(for: draft([.topology(.connect(.init(cable: cable)))]), in: namespace)
        XCTAssertEqual(issues, [])
    }

    func testDisconnectTombstonesTheCableWithItsExactMirrorPrecondition() async throws {
        let cable = topology.patch()
        let (planner, namespace) = try await makePlanner(topology.records(in: ServiceFixture.namespace(), cables: [cable]))
        let command = TopologyCommand.disconnect(DisconnectTopologyCommand(cableID: cable.id, deletedAt: completedAt))

        let material = try await planner.materializeCompletion(of: order([.topology(command)]), at: completedAt, in: namespace)

        XCTAssertTrue(material.saves.isEmpty)
        XCTAssertEqual(material.tombstones.map(\.resourceKey), [.object(cable.id)])
        XCTAssertEqual(material.tombstones.first?.recordType, "Cable")
        XCTAssertEqual(material.tombstones.first?.deletedAt, completedAt)
        XCTAssertEqual(
            material.touchedPreconditions, [.object(cable.id): .exactSystemFields(.object(cable.id), ServiceFixture.exact("cable-\(cable.id)"))])
    }

    func testConnectingAnOccupiedPortIsRejected() async throws {
        let existing = topology.patch()
        let (planner, namespace) = try await makePlanner(topology.records(in: ServiceFixture.namespace(), cables: [existing]))
        let second = topology.patch(id: 31, from: topology.switchPort, to: topology.spareSwitchPort)
        let operations: [PlannedWorkOperation] = [.topology(.connect(.init(cable: second)))]

        let issues = try await planner.issues(for: draft(operations), in: namespace)

        XCTAssertFalse(issues.isEmpty, "A port may carry only one installed cable.")
        await assertThrowsAny { try await planner.materializeCompletion(of: self.order(operations), at: self.completedAt, in: namespace) }
    }

    func testUnsupportedAndLegacyOperationsAreRejected() async throws {
        let (planner, namespace) = try await makePlanner(topology.records(in: ServiceFixture.namespace()))
        let remove = PlannedWorkOperation.topology(.remove(RemoveTopologyCommand(deviceID: topology.panelDevice.id)))
        let generic = PlannedWorkOperation.device(resourceKey: .object(topology.panelDevice.id), description: "Update")
        let legacy = PlannedWorkOperation.ipam(.legacyVLANMembership(interfaceID: ObjectID(), vlanID: ObjectID(), isNative: true))

        await assertThrows(ProductionMutationPlannerError.unsupportedGenericDeviceOperation) {
            try await planner.materializeCompletion(of: self.order([remove]), at: self.completedAt, in: namespace)
        }
        await assertThrows(ProductionMutationPlannerError.unsupportedGenericDeviceOperation) {
            try await planner.materializeCompletion(of: self.order([generic]), at: self.completedAt, in: namespace)
        }
        await assertThrows(ProductionMutationPlannerError.legacyIntentRequiresReconciliation) {
            try await planner.materializeCompletion(of: self.order([legacy]), at: self.completedAt, in: namespace)
        }
        for operation in [remove, generic, legacy] {
            let issues = try await planner.issues(for: draft([operation]), in: namespace)
            XCTAssertEqual(issues.count, 1)
        }
    }

    func testPlanningOutsideTheAccountNamespaceIsRejected() async throws {
        let (planner, _) = try await makePlanner(topology.records(in: ServiceFixture.namespace()))

        await assertThrows(ProductionMutationPlannerError.namespaceMismatch) {
            try await planner.materializeCompletion(
                of: self.order([.topology(.connect(.init(cable: self.topology.patch())))]), at: self.completedAt, in: ServiceFixture.namespace())
        }
    }

    func testMirrorWithoutAnActiveWorkspaceSentinelCannotBePlanned() async throws {
        let namespace = ServiceFixture.namespace()
        let store = try ServiceFixture.makeStore()
        try await ServiceFixture.seed(store, namespace: namespace, records: topology.records(in: namespace))
        let planner = SwiftDataProductionMutationPlanner(persistence: store, account: ServiceFixture.account(namespace))

        await assertThrowsAny {
            try await planner.materializeCompletion(
                of: self.order([.topology(.connect(.init(cable: self.topology.patch())))]), at: self.completedAt, in: namespace)
        }
    }

    // MARK: IPAM

    func testAddressAssignmentPlansTheAssignmentAndTheAddressCompatibilityMirror() async throws {
        let namespace = ServiceFixture.namespace()
        let ipam = IPAMFixture(deviceID: topology.switchDevice.id)
        let (planner, _) = try await makePlanner(topology.records(in: namespace) + ipam.records(in: namespace), namespace: namespace)
        let assignment = IPAddressAssignment(id: TopologyFixture.id(300), addressID: ipam.address.id, interfaceID: ipam.interface.id, isPrimary: true)
        let set = InterfaceAddressAssignmentSet(
            revisionVRF: ipam.vrf, interfaceID: ipam.interface.id, currentAssignments: [], desiredAssignments: [assignment], primaryAddressID: ipam.address.id)

        let material = try await planner.materializeCompletion(of: order([.ipam(.addressAssignment(set))]), at: completedAt, in: namespace)

        let addressKey = ResourceKey.string(ipam.address.id)
        XCTAssertEqual(Set(material.saves.map(\.resourceKey)), [.object(assignment.id), addressKey])
        XCTAssertEqual(material.touchedPreconditions[.object(assignment.id)], .mustNotExist(.object(assignment.id)))
        XCTAssertEqual(material.touchedPreconditions[addressKey], .exactSystemFields(addressKey, ServiceFixture.exact("address")))
        let savedAddress = try decode(IPAddressRecord.self, material.saves.first { $0.resourceKey == addressKey }?.encodedRecord)
        XCTAssertEqual(savedAddress.assignedInterfaceID, ipam.interface.id)
    }

    func testAddressAssignmentWithAStaleCurrentSetIsRejected() async throws {
        let namespace = ServiceFixture.namespace()
        let ipam = IPAMFixture(deviceID: topology.switchDevice.id)
        let (planner, _) = try await makePlanner(topology.records(in: namespace) + ipam.records(in: namespace), namespace: namespace)
        let phantom = IPAddressAssignment(addressID: ipam.otherAddress.id, interfaceID: ipam.interface.id, isPrimary: true)
        let set = InterfaceAddressAssignmentSet(
            revisionVRF: ipam.vrf, interfaceID: ipam.interface.id, currentAssignments: [phantom], desiredAssignments: [], primaryAddressID: nil)

        await assertThrows(ProductionMutationPlannerError.staleIPAMRelationshipSet(.object(ipam.interface.id))) {
            try await planner.materializeCompletion(of: self.order([.ipam(.addressAssignment(set))]), at: self.completedAt, in: namespace)
        }
    }

    func testPrefixLayoutAdvancesTheVRFRevisionAndPlansNewPrefixes() async throws {
        let namespace = ServiceFixture.namespace()
        let ipam = IPAMFixture(deviceID: topology.switchDevice.id)
        let (planner, _) = try await makePlanner(ipam.records(in: namespace), namespace: namespace)
        let added = Prefix(id: TopologyFixture.id(301), vrfID: ipam.vrf.id, cidr: "198.51.100.0/24", name: "Servers").unsafelyUnwrappedForFixture
        let operation = PlannedIPAMOperation.prefixLayout(
            vrf: ipam.vrf, expectedRevision: ipam.vrf.revision, currentPrefixes: [ipam.prefix], desiredPrefixes: [ipam.prefix, added])

        let material = try await planner.materializeCompletion(of: order([.ipam(operation)]), at: completedAt, in: namespace)

        let vrfKey = ResourceKey.object(ipam.vrf.id)
        XCTAssertEqual(try decode(VRF.self, material.saves.first { $0.resourceKey == vrfKey }?.encodedRecord).revision, ipam.vrf.revision + 1)
        XCTAssertEqual(material.touchedPreconditions[vrfKey], .exactSystemFields(vrfKey, ServiceFixture.exact("vrf")))
        XCTAssertEqual(material.touchedPreconditions[.object(added.id)], .mustNotExist(.object(added.id)))
        XCTAssertTrue(material.tombstones.isEmpty)
    }

    func testPrefixLayoutRequiresTheCurrentVRFRevision() async throws {
        let namespace = ServiceFixture.namespace()
        let ipam = IPAMFixture(deviceID: topology.switchDevice.id)
        let (planner, _) = try await makePlanner(ipam.records(in: namespace), namespace: namespace)
        var staleVRF = ipam.vrf
        staleVRF.revision -= 1
        let stale = PlannedIPAMOperation.prefixLayout(
            vrf: staleVRF, expectedRevision: staleVRF.revision, currentPrefixes: [ipam.prefix], desiredPrefixes: [ipam.prefix])
        let wrongToken = PlannedIPAMOperation.prefixLayout(
            vrf: ipam.vrf, expectedRevision: ipam.vrf.revision - 1, currentPrefixes: [ipam.prefix], desiredPrefixes: [ipam.prefix])

        await assertThrows(ProductionMutationPlannerError.missingIPAMObject(.object(ipam.vrf.id))) {
            try await planner.materializeCompletion(of: self.order([.ipam(stale)]), at: self.completedAt, in: namespace)
        }
        await assertThrows(IPAMValidationError.revisionConflict(vrfID: ipam.vrf.id, expected: ipam.vrf.revision - 1, actual: ipam.vrf.revision)) {
            try await planner.materializeCompletion(of: self.order([.ipam(wrongToken)]), at: self.completedAt, in: namespace)
        }
    }

    // MARK: Hierarchy

    func testUpsertRackPlansTheRackAndRevisionsItsParentLocation() async throws {
        let namespace = ServiceFixture.namespace()
        let hierarchy = HierarchyFixture()
        let (planner, _) = try await makePlanner([], namespace: namespace)
        let rack = Rack(id: TopologyFixture.id(400), assetCode: "RACK-102", locationID: hierarchy.room.id, heightRU: 24)

        let material = try await planner.materializeCompletion(of: order([.hierarchy(.upsertRack(rack))]), at: completedAt, in: namespace)

        let roomKey = ResourceKey.object(hierarchy.room.id)
        XCTAssertEqual(Set(material.saves.map(\.resourceKey)), [.object(rack.id), roomKey])
        XCTAssertEqual(try decode(Rack.self, material.saves.first { $0.resourceKey == .object(rack.id) }?.encodedRecord), rack)
        XCTAssertEqual(material.touchedPreconditions[.object(rack.id)], .mustNotExist(.object(rack.id)))
        XCTAssertEqual(material.touchedPreconditions[roomKey], .exactSystemFields(roomKey, ServiceFixture.exact("location-\(hierarchy.room.id)")))
    }

    func testRemoveRackSoftDeletesItAtTheCompletionTime() async throws {
        let namespace = ServiceFixture.namespace()
        let hierarchy = HierarchyFixture()
        let (planner, _) = try await makePlanner([], namespace: namespace)

        let material = try await planner.materializeCompletion(of: order([.hierarchy(.removeRack(hierarchy.rack))]), at: completedAt, in: namespace)

        let rackKey = ResourceKey.object(hierarchy.rack.id)
        XCTAssertEqual(try decode(Rack.self, material.saves.first { $0.resourceKey == rackKey }?.encodedRecord).deletedAt, completedAt)
        XCTAssertEqual(material.touchedPreconditions[rackKey], .exactSystemFields(rackKey, ServiceFixture.exact("rack-\(hierarchy.rack.id)")))
    }

    func testInvalidHierarchyOperationsAreRejected() async throws {
        let namespace = ServiceFixture.namespace()
        let hierarchy = HierarchyFixture()
        let (planner, _) = try await makePlanner([], namespace: namespace)
        var deleted = hierarchy.room
        deleted.deletedAt = completedAt
        let unknownRack = Rack(assetCode: "RACK-404", locationID: hierarchy.room.id, heightRU: 42)

        await assertThrows(ProductionMutationPlannerError.invalidHierarchyOperation) {
            try await planner.materializeCompletion(of: self.order([.hierarchy(.upsertLocation(deleted))]), at: self.completedAt, in: namespace)
        }
        await assertThrows(ProductionMutationPlannerError.missingHierarchyObject(.object(unknownRack.id))) {
            try await planner.materializeCompletion(of: self.order([.hierarchy(.removeRack(unknownRack))]), at: self.completedAt, in: namespace)
        }
    }

    // MARK: Helpers

    /// Every planned snapshot includes the fixture hierarchy: the planner
    /// validates template placement state, which requires a workspace root.
    private func makePlanner(
        _ records: [LocalMirrorRecord], namespace: PersistenceNamespace? = nil
    ) async throws -> (SwiftDataProductionMutationPlanner, PersistenceNamespace) {
        guard let resolved = namespace ?? records.first?.namespace else { throw ServiceTestError(reason: "no namespace") }
        let store = try ServiceFixture.makeStore()
        let hierarchy = try HierarchyFixture().records(in: resolved)
        try await ServiceFixture.seed(store, namespace: resolved, records: records + hierarchy + [ServiceFixture.sentinelMirror(resolved)])
        return (SwiftDataProductionMutationPlanner(persistence: store, account: ServiceFixture.account(resolved)), resolved)
    }

    private func order(_ operations: [PlannedWorkOperation]) -> WorkOrder {
        WorkOrder(kind: .connect, title: "Planned change", creatorID: "owner", plannedOperations: operations)
    }

    private func draft(_ operations: [PlannedWorkOperation]) -> WorkOrderDraft {
        WorkOrderDraft(title: "Planned change", ticket: "CHG-1", operations: operations)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data?) throws -> T {
        guard let data else { throw ServiceTestError(reason: "missing planned record") }
        return try CloudDeterministicCoding.decode(type, from: data)
    }
}
