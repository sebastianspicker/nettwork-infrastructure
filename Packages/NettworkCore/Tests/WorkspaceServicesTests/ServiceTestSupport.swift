import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import SwiftData
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Fixture builders shared by the infrastructure service characterization
/// tests. They mirror the package test patterns (in-memory SwiftData store,
/// deterministic Cloud coding, exact system fields) because package test
/// helpers are not importable from the app test bundle.
enum ServiceFixture {
    static let containerIdentifier = "iCloud.example.nettwork.service-tests"
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func namespace(owner: String = "owner", workspaceID: ObjectID = ObjectID(), generation: UInt64 = 1) -> PersistenceNamespace {
        PersistenceNamespace(
            containerIdentifier: containerIdentifier, cloudKitAccountRecordName: owner, workspaceID: workspaceID,
            zoneName: CloudRecordNaming.zoneName(for: workspaceID), zoneOwnerRecordName: owner, sessionGeneration: generation)
    }

    static func account(_ namespace: PersistenceNamespace, permission: WorkspaceSharePermission = .owner) -> AccountContext {
        AccountContext(namespace: namespace, databaseScope: .ownerPrivate, sharePermission: permission, verifiedAt: epoch)
    }

    static func actor(for account: AccountContext, role: OfficialClientRole = .administrator, installationID: String = "installation-1") -> ActorContext {
        ActorContext(
            cloudKitUserRecordName: account.namespace.cloudKitAccountRecordName, role: role, installationID: installationID,
            sessionGeneration: account.namespace.sessionGeneration)
    }

    static func presentation(for actor: ActorContext, isFresh: Bool = true) -> OperationsAuthorization {
        OperationsAuthorization(actorID: actor.cloudKitUserRecordName, role: actor.role, sessionGeneration: actor.sessionGeneration, isFresh: isFresh)
    }

    static func makeStore() throws -> SwiftDataPersistenceStore {
        let container = try NettworkPersistenceContainerFactory.make(configuration: ModelConfiguration(isStoredInMemoryOnly: true))
        return SwiftDataPersistenceStore(
            container: container, attachmentDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    }

    /// Payload dates must survive millisecond JSON coding exactly.
    static func wholeSeconds(fromNow offset: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 + offset).rounded(.down))
    }

    static func exact(_ tag: String) -> ExactRecordPrecondition {
        ExactRecordPrecondition(systemFields: Data("fields-\(tag)".utf8), changeTag: tag)
    }

    static func mirror<T: Encodable>(
        _ value: T, key: ResourceKey, type: String, namespace: PersistenceNamespace, tag: String = "tag-1", modifiedAt: Date = epoch
    ) throws -> LocalMirrorRecord {
        LocalMirrorRecord(
            namespace: namespace, resourceKey: key, recordType: type, schemaVersion: 1, payload: try CloudDeterministicCoding.encode(value),
            systemFields: Data("fields-\(tag)".utf8), changeTag: tag, isTombstone: false, serverModifiedAt: modifiedAt, verifiedAt: modifiedAt)
    }

    static func mirror<T: Encodable & Identifiable>(
        _ value: T, type: String, namespace: PersistenceNamespace, tag: String = "tag-1"
    ) throws -> LocalMirrorRecord where T.ID == ObjectID {
        try mirror(value, key: .object(value.id), type: type, namespace: namespace, tag: tag)
    }

    static func activeLifecycle(memberCount: Int = 0) -> WorkspaceLifecycle {
        .active(commit: WorkspaceActivationCommit(transferID: ObjectID(), memberCount: memberCount, rollingDigest: "service-tests"))
    }

    static func workspaceRecord(_ namespace: PersistenceNamespace, lifecycle: WorkspaceLifecycle) -> CloudWorkspaceRecord {
        CloudWorkspaceRecord(
            workspaceID: namespace.workspaceID, zoneName: namespace.zoneName, zoneOwnerRecordName: namespace.zoneOwnerRecordName, lifecycle: lifecycle)
    }

    static func sentinelKey(_ namespace: PersistenceNamespace) -> ResourceKey {
        AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
    }

    /// The hidden workspace sentinel that revisions every planner snapshot.
    static func sentinelMirror(
        _ namespace: PersistenceNamespace, tag: String = "workspace-active", lifecycle: WorkspaceLifecycle = activeLifecycle()
    ) throws -> LocalMirrorRecord {
        LocalMirrorRecord(
            namespace: namespace, resourceKey: sentinelKey(namespace), recordType: CloudRecordNaming.workspaceRecordType,
            schemaVersion: CloudRecordNaming.schemaVersion,
            payload: try CloudDeterministicCoding.encode(workspaceRecord(namespace, lifecycle: lifecycle)),
            systemFields: Data("fields-\(tag)".utf8), changeTag: tag, isTombstone: false, serverModifiedAt: epoch, verifiedAt: epoch)
    }

    /// Activates the namespace lease (revoking all others) and applies one
    /// verified batch with an active workspace visibility state.
    static func seed(_ store: SwiftDataPersistenceStore, namespace: PersistenceNamespace, records: [LocalMirrorRecord]) async throws {
        _ = await store.activateLease(for: namespace)
        try await store.repairMirrorMaintenanceIndexes(records: [], maintenance: LocalMirrorMaintenanceBatch(records: []), in: namespace)
        let visibility = LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: activeLifecycle(memberCount: records.count), updatedAt: epoch)
        try await store.applyVerifiedMirrorBatch(
            LocalMirrorBatch(
                records: records, workspaceVisibility: visibility,
                maintenance: LocalMirrorMaintenanceBatch(records: records.map { LocalMirrorMaintenanceRecord(resourceKey: $0.resourceKey) })),
            in: namespace)
    }

    static func auditEvent(ticket: String, at offset: TimeInterval) -> AuditEvent {
        AuditEvent(
            operationID: ObjectID(), actorID: "owner", affectedObjectIDs: [], occurredAt: epoch.addingTimeInterval(offset), result: .accepted, ticket: ticket)
    }

    static func auditRecord(_ event: AuditEvent, _ namespace: PersistenceNamespace) throws -> LocalMirrorRecord {
        try mirror(event, type: CloudRecordNaming.auditRecordType, namespace: namespace, tag: "audit-\(event.id)")
    }

    static func operationBoundary() throws -> ProductionOperationBoundary {
        try ProductionOperationBoundary(
            policies: BoundedOperationKind.allCases.map {
                BoundedOperationPolicy(operation: $0, maximumConcurrentOperations: 4, cancellationCheckInterval: 1)
            },
            budgets: BoundedOperationKind.allCases.map { OperationPerformanceBudget(operation: $0, maximumWallClockMilliseconds: 600_000) },
            measurementSink: DiscardingMeasurementSink())
    }
}

struct DiscardingMeasurementSink: PrivacySafeOperationMeasurementRecording {
    func record(_: PrivacySafeOperationMeasurement) async {}
}

/// A small, valid physical topology with a switch and a patch panel. IDs are
/// fixed so failures are readable and ordering is deterministic.
struct TopologyFixture {
    let switchType = DeviceType(id: TopologyFixture.id(1), name: "Access switch", kind: .switchDevice)
    let panelType = DeviceType(id: TopologyFixture.id(2), name: "Patch panel", kind: .passive)
    let switchDevice: Device
    let panelDevice: Device
    let switchPort: NetworkModel.Port
    let panelPort: NetworkModel.Port
    let spareSwitchPort: NetworkModel.Port

    init() {
        switchDevice = Device(id: Self.id(10), assetCode: "SW-1", name: "Switch 1", typeID: switchType.id)
        panelDevice = Device(id: Self.id(11), assetCode: "PP-1", name: "Panel 1", typeID: panelType.id)
        switchPort = NetworkModel.Port(id: Self.id(20), deviceID: switchDevice.id, label: "Gi1/0/1", medium: .copper, connector: .rj45)
        spareSwitchPort = NetworkModel.Port(id: Self.id(21), deviceID: switchDevice.id, label: "Gi1/0/2", medium: .copper, connector: .rj45)
        panelPort = NetworkModel.Port(id: Self.id(22), deviceID: panelDevice.id, label: "1", medium: .copper, connector: .rj45)
    }

    static func id(_ value: Int) -> ObjectID {
        ObjectID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", value)) ?? UUID())
    }

    func patch(id: Int = 30, from: NetworkModel.Port? = nil, to: NetworkModel.Port? = nil) -> Cable {
        Cable(
            id: Self.id(id), assetCode: AssetCode("PATCH-\(id)"), endpointA: (from ?? switchPort).id, endpointB: (to ?? panelPort).id, medium: .copper,
            connector: .rj45, kind: .patchCord, status: .installed)
    }

    func records(in namespace: PersistenceNamespace, cables: [Cable] = []) throws -> [LocalMirrorRecord] {
        var result = [
            try ServiceFixture.mirror(switchType, type: "NettworkDeviceType", namespace: namespace),
            try ServiceFixture.mirror(panelType, type: "NettworkDeviceType", namespace: namespace),
            try ServiceFixture.mirror(switchDevice, type: "NettworkDevice", namespace: namespace),
            try ServiceFixture.mirror(panelDevice, type: "NettworkDevice", namespace: namespace),
            try ServiceFixture.mirror(switchPort, type: "NettworkPort", namespace: namespace),
            try ServiceFixture.mirror(spareSwitchPort, type: "NettworkPort", namespace: namespace),
            try ServiceFixture.mirror(panelPort, type: "NettworkPort", namespace: namespace),
        ]
        for cable in cables {
            result.append(try ServiceFixture.mirror(cable, type: "NettworkCable", namespace: namespace, tag: "cable-\(cable.id)"))
        }
        return result
    }
}

/// Workspace → site → building → floor → room plus one rack in the room.
struct HierarchyFixture {
    let workspace = Location(id: TopologyFixture.id(100), name: "Example", kind: .workspace)
    let site: Location
    let building: Location
    let floor: Location
    let room: Location
    let rack: Rack

    init() {
        site = Location(id: TopologyFixture.id(101), name: "Main site", kind: .site, parentID: workspace.id)
        building = Location(id: TopologyFixture.id(102), name: "Building A", kind: .building, parentID: site.id)
        floor = Location(id: TopologyFixture.id(103), name: "Floor 1", kind: .floor, parentID: building.id)
        room = Location(id: TopologyFixture.id(104), name: "Room 101", kind: .room, parentID: floor.id)
        rack = Rack(id: TopologyFixture.id(105), assetCode: "RACK-101", locationID: room.id, heightRU: 42)
    }

    var locations: [Location] { [workspace, site, building, floor, room] }

    func records(in namespace: PersistenceNamespace) throws -> [LocalMirrorRecord] {
        try locations.map { try ServiceFixture.mirror($0, type: "NettworkLocation", namespace: namespace, tag: "location-\($0.id)") }
            + [try ServiceFixture.mirror(rack, type: "NettworkRack", namespace: namespace, tag: "rack-\(rack.id)")]
    }
}

/// One VRF with a /24, one routed loopback interface and two unassigned
/// addresses.
struct IPAMFixture {
    let vrf = VRF(id: TopologyFixture.id(200), name: "Corporate", revision: 3)
    let prefix: Prefix
    let interface: Interface
    let address: IPAddressRecord
    let otherAddress: IPAddressRecord

    init(deviceID: ObjectID) {
        prefix = Prefix(id: TopologyFixture.id(201), vrfID: vrf.id, cidr: "192.0.2.0/24", name: "Users").unsafelyUnwrappedForFixture
        interface = Interface(id: TopologyFixture.id(202), deviceID: deviceID, name: "Loopback0", mode: .routed, kind: .loopback)
        address = IPAddressRecord(vrfID: vrf.id, address: IPAddress(parsing: "192.0.2.10").unsafelyUnwrappedForFixture)
        otherAddress = IPAddressRecord(vrfID: vrf.id, address: IPAddress(parsing: "192.0.2.20").unsafelyUnwrappedForFixture)
    }

    func records(in namespace: PersistenceNamespace) throws -> [LocalMirrorRecord] {
        [
            try ServiceFixture.mirror(vrf, type: "NettworkVRF", namespace: namespace, tag: "vrf"),
            try ServiceFixture.mirror(prefix, type: "NettworkPrefix", namespace: namespace, tag: "prefix"),
            try ServiceFixture.mirror(interface, type: "NettworkInterface", namespace: namespace, tag: "interface"),
            try ServiceFixture.mirror(address, key: .string(address.id), type: "NettworkIPAddressRecord", namespace: namespace, tag: "address"),
            try ServiceFixture.mirror(otherAddress, key: .string(otherAddress.id), type: "NettworkIPAddressRecord", namespace: namespace, tag: "other"),
        ]
    }
}

extension Optional {
    /// Fixture literals are statically valid; a nil here is a broken fixture.
    var unsafelyUnwrappedForFixture: Wrapped {
        guard let value = self else { preconditionFailure("Invalid static test fixture.") }
        return value
    }
}
