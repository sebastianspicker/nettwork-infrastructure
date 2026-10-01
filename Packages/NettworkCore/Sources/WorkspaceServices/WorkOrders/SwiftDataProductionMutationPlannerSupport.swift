import CloudSync
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

struct MaterializationInputs {
    let records: [LocalMirrorRecord]
    let preconditions: [ResourceKey: MutationPrecondition]
    let assertions: [ResourceKey: AuthoritativeReadAssertion]
}

let plannerRecordTypes: Set<String> = [
    WorkspaceRecordType.physicalTopology, LocalRecordKind.physicalTopology,
    WorkspaceRecordType.deviceType, WorkspaceRecordType.Legacy.deviceType, WorkspaceRecordType.moduleTemplate, WorkspaceRecordType.Legacy.moduleTemplate,
    WorkspaceRecordType.device, WorkspaceRecordType.Legacy.device,
    WorkspaceRecordType.module, WorkspaceRecordType.Legacy.module, WorkspaceRecordType.port, WorkspaceRecordType.Legacy.port,
    WorkspaceRecordType.cable, WorkspaceRecordType.Legacy.cable, WorkspaceRecordType.internalLink, WorkspaceRecordType.Legacy.internalLink,
    WorkspaceRecordType.vrf, WorkspaceRecordType.Legacy.vrf, WorkspaceRecordType.prefix, LocalRecordKind.prefix, WorkspaceRecordType.Legacy.prefix,
    WorkspaceRecordType.ipAddressRecord, WorkspaceRecordType.Legacy.ipAddressRecord, WorkspaceRecordType.vlan, WorkspaceRecordType.Legacy.vlan,
    WorkspaceRecordType.interface, WorkspaceRecordType.Legacy.interface, WorkspaceRecordType.ipAddressAssignment,
    WorkspaceRecordType.Legacy.ipAddressAssignment,
    WorkspaceRecordType.interfaceVLANMembership, WorkspaceRecordType.Legacy.interfaceVLANMembership,
    WorkspaceRecordType.workspaceHierarchy, WorkspaceRecordType.Legacy.workspaceHierarchy, WorkspaceRecordType.location, WorkspaceRecordType.Legacy.location,
    WorkspaceRecordType.rack, WorkspaceRecordType.Legacy.rack, WorkspaceRecordType.hierarchyTombstone, WorkspaceRecordType.Legacy.hierarchyTombstone,
    WorkspaceRecordType.rackPlacement, WorkspaceRecordType.Legacy.rackPlacement,
    WorkspaceRecordType.floorPlanAnchor, WorkspaceRecordType.Legacy.floorPlanAnchor, WorkspaceRecordType.templatePlacementState,
    WorkspaceRecordType.Legacy.templatePlacementState,
]

func materializationInputs(from records: [LocalMirrorRecord]) throws -> MaterializationInputs {
    guard let namespace = records.first?.namespace,
        records.allSatisfy({ $0.namespace == namespace })
    else {
        throw ProductionMutationPlannerError.namespaceMismatch
    }
    let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
    let sentinel = try validatedSentinel(in: records, namespace: namespace, key: sentinelKey)
    let candidates = records.filter {
        !$0.isTombstone && $0.payload != nil && plannerRecordTypes.contains($0.recordType)
    }
    let assertions = [
        sentinelKey: AuthoritativeReadAssertion(
            resourceKey: sentinelKey, recordType: CloudRecordNaming.workspaceRecordType, schemaVersion: sentinel.record.schemaVersion,
            encodedRecord: sentinel.payload, precondition: sentinel.precondition
        )
    ]
    return MaterializationInputs(
        records: candidates,
        preconditions: try materializationPreconditions(candidates),
        assertions: assertions
    )
}

private func validatedSentinel(
    in records: [LocalMirrorRecord], namespace: PersistenceNamespace, key: ResourceKey
) throws -> (record: LocalMirrorRecord, payload: Data, precondition: ExactRecordPrecondition) {
    let sentinels = records.filter {
        $0.resourceKey == key && $0.recordType == CloudRecordNaming.workspaceRecordType && !$0.isTombstone
    }
    guard sentinels.count == 1,
        let payload = sentinels[0].payload,
        let exact = sentinels[0].exactPrecondition,
        let workspace = canonicalDecoded(CloudWorkspaceRecord.self, from: payload),
        workspace.workspaceID == namespace.workspaceID,
        workspace.zoneName == namespace.zoneName,
        workspace.zoneOwnerRecordName == namespace.zoneOwnerRecordName,
        case .active = workspace.lifecycle
    else {
        throw ProductionMutationPlannerError.missingMirrorPrecondition(key)
    }
    return (sentinels[0], payload, exact)
}

private func materializationPreconditions(_ records: [LocalMirrorRecord]) throws -> [ResourceKey: MutationPrecondition] {
    var result: [ResourceKey: MutationPrecondition] = [:]
    for record in records {
        guard let exact = record.exactPrecondition,
            CloudRecordNaming.canonicalRecordType(record.recordType) != nil
        else {
            throw ProductionMutationPlannerError.missingMirrorPrecondition(record.resourceKey)
        }
        guard
            result.updateValue(
                .exactSystemFields(record.resourceKey, exact),
                forKey: record.resourceKey
            ) == nil
        else {
            throw ProductionMutationPlannerError.duplicateMutation(record.resourceKey)
        }
    }
    return result
}

struct Snapshot {
    var topology: PhysicalTopology
    var hierarchy: WorkspaceHierarchy
    var placements: [RackPlacement]
    var rackReservations: [RackPlacementReservation]
    var anchors: [FloorPlanAnchor]
    var deviceTypes: [ObjectID: DeviceType]
    var moduleTemplates: [ObjectID: ModuleTemplate]
    var devices: [ObjectID: Device]
    var vrfs: [ObjectID: VRF]
    var prefixes: [ObjectID: Prefix]
    var addresses: [String: IPAddressRecord]
    var vlans: [ObjectID: VLAN]
    var interfaces: [ObjectID: Interface]
    var assignments: [ObjectID: IPAddressAssignment]
    var memberships: [ObjectID: InterfaceVLANMembership]

    init(records: [LocalMirrorRecord]) throws {
        let normalized = try ProductionMirrorDomainProjection(records: records)
        let live = records.filter { !$0.isTombstone && $0.payload != nil }
        func values<T: Decodable>(_ type: T.Type, names: Set<String>) throws -> [T] {
            try live.filter { names.contains($0.recordType) }.map { record in
                guard let payload = record.payload,
                    let value = try? CloudDeterministicCoding.decode(type, from: payload)
                else {
                    throw ProductionMutationPlannerError.malformedMirrorRecord(record.resourceKey)
                }
                return value
            }
        }
        topology = normalized.topology
        hierarchy = normalized.hierarchy
        placements = normalized.placements
        rackReservations = normalized.rackReservations
        anchors = normalized.anchors
        deviceTypes = Dictionary(topology.deviceTypes.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        moduleTemplates = Dictionary(normalized.moduleTemplates.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        self.devices = Dictionary(topology.devices.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let vrfs: [VRF] = try values(VRF.self, names: [WorkspaceRecordType.vrf, WorkspaceRecordType.Legacy.vrf])
        let prefixes: [Prefix] = try values(Prefix.self, names: [WorkspaceRecordType.prefix, LocalRecordKind.prefix, WorkspaceRecordType.Legacy.prefix])
        let addresses: [IPAddressRecord] = try values(
            IPAddressRecord.self, names: [WorkspaceRecordType.ipAddressRecord, WorkspaceRecordType.Legacy.ipAddressRecord])
        let vlans: [VLAN] = try values(VLAN.self, names: [WorkspaceRecordType.vlan, WorkspaceRecordType.Legacy.vlan])
        let interfaces: [Interface] = try values(Interface.self, names: [WorkspaceRecordType.interface, WorkspaceRecordType.Legacy.interface])
        let assignments: [IPAddressAssignment] = try values(
            IPAddressAssignment.self, names: [WorkspaceRecordType.ipAddressAssignment, WorkspaceRecordType.Legacy.ipAddressAssignment])
        let memberships: [InterfaceVLANMembership] = try values(
            InterfaceVLANMembership.self,
            names: [
                WorkspaceRecordType.interfaceVLANMembership,
                WorkspaceRecordType.Legacy.interfaceVLANMembership,
            ])
        self.vrfs = Dictionary(vrfs.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        self.prefixes = Dictionary(prefixes.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        self.addresses = Dictionary(addresses.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        self.vlans = Dictionary(vlans.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        self.interfaces = Dictionary(interfaces.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        self.assignments = Dictionary(assignments.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        self.memberships = Dictionary(memberships.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
    }
}

struct ChangeAccumulator {
    let deletedAt: Date
    private var saves: [ResourceKey: AuthoritativeRecordSave] = [:]
    private var tombstones: [ResourceKey: AuthoritativeTombstone] = [:]
    private var sourcePreconditions: [ResourceKey: MutationPrecondition]
    private var sourceAssertions: [ResourceKey: AuthoritativeReadAssertion]

    init(deletedAt: Date, sourcePreconditions: [ResourceKey: MutationPrecondition], sourceAssertions: [ResourceKey: AuthoritativeReadAssertion]) {
        self.deletedAt = deletedAt
        self.sourcePreconditions = sourcePreconditions
        self.sourceAssertions = sourceAssertions
    }

    mutating func save<T: Encodable & Identifiable>(_ value: T, recordType: String) throws where T.ID == ObjectID {
        try saveStringKeyed(value, resourceKey: .object(value.id), recordType: recordType)
    }

    mutating func saveStringKeyed<T: Encodable>(_ value: T, resourceKey: ResourceKey, recordType: String) throws {
        guard tombstones[resourceKey] == nil else { throw ProductionMutationPlannerError.duplicateMutation(resourceKey) }
        saves[resourceKey] = AuthoritativeRecordSave(
            resourceKey: resourceKey,
            recordType: recordType,
            schemaVersion: 1,
            encodedRecord: try CloudDeterministicCoding.encode(value)
        )
    }

    mutating func tombstone<T: Encodable & Identifiable>(_ value: T, recordType: String) throws where T.ID == ObjectID {
        try tombstone(value, resourceKey: .object(value.id), recordType: recordType)
    }

    mutating func tombstone<T: Encodable>(_ value: T, resourceKey: ResourceKey, recordType: String) throws {
        let key = resourceKey
        guard saves[key] == nil else { throw ProductionMutationPlannerError.duplicateMutation(key) }
        tombstones[key] = AuthoritativeTombstone(
            resourceKey: key,
            recordType: recordType,
            deletedAt: deletedAt,
            encodedTombstone: try CloudDeterministicCoding.encode(value)
        )
    }

    mutating func captureTopologyDifference(before: PhysicalTopology, after: PhysicalTopology) throws {
        try capture(before.deviceTypes, after.deviceTypes, recordType: WorkspaceRecordType.Legacy.deviceType)
        try capture(before.devices, after.devices, recordType: WorkspaceRecordType.Legacy.device)
        try capture(before.modules, after.modules, recordType: WorkspaceRecordType.Legacy.module)
        try capture(before.ports, after.ports, recordType: WorkspaceRecordType.Legacy.port)
        try capture(before.cables, after.cables, recordType: WorkspaceRecordType.Legacy.cable)
        try capture(before.internalLinks, after.internalLinks, recordType: WorkspaceRecordType.Legacy.internalLink)
    }

    mutating func material() throws -> ProductionMutationMaterial {
        let overlap = Set(saves.keys).intersection(tombstones.keys)
        if let key = overlap.first { throw ProductionMutationPlannerError.duplicateMutation(key) }
        let touchedKeys = Set(saves.keys).union(tombstones.keys)
        var touchedPreconditions: [ResourceKey: MutationPrecondition] = [:]
        for key in touchedKeys {
            touchedPreconditions[key] = sourcePreconditions.removeValue(forKey: key) ?? .mustNotExist(key)
            sourceAssertions.removeValue(forKey: key)
        }
        return ProductionMutationMaterial(
            saves: saves.values.sorted { $0.resourceKey < $1.resourceKey },
            tombstones: tombstones.values.sorted { $0.resourceKey < $1.resourceKey },
            touchedPreconditions: touchedPreconditions,
            readOnlyDependencies: sourceAssertions.values.sorted { $0.resourceKey < $1.resourceKey }
        )
    }

    private mutating func capture<T: Encodable & Identifiable & Equatable>(_ before: [T], _ after: [T], recordType: String) throws where T.ID == ObjectID {
        let old = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        let new = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { current, _ in current })
        for value in new.values where old[value.id] != value { try save(value, recordType: recordType) }
        for value in old.values where new[value.id] == nil { try tombstone(value, recordType: recordType) }
    }
}
