import CloudSync
import ContentSafety
import CryptoKit
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

struct MirrorProjection {
    static let featureRecordTypes: Set<String> = [
        WorkspaceRecordType.physicalTopology, LocalRecordKind.physicalTopology,
        WorkspaceRecordType.deviceType, WorkspaceRecordType.moduleTemplate, WorkspaceRecordType.device, WorkspaceRecordType.module, WorkspaceRecordType.port,
        WorkspaceRecordType.cable, WorkspaceRecordType.internalLink, WorkspaceRecordType.topologyTombstone,
        WorkspaceRecordType.workspaceHierarchy, WorkspaceRecordType.location, WorkspaceRecordType.rack,
        WorkspaceRecordType.hierarchyTombstone, WorkspaceRecordType.templatePlacementState, WorkspaceRecordType.rackPlacement,
        WorkspaceRecordType.floorPlanAnchor, WorkspaceRecordType.Legacy.floorPlanAnchor,
        WorkspaceRecordType.vrf, WorkspaceRecordType.prefix,
        LocalRecordKind.prefix, WorkspaceRecordType.ipAddressRecord, WorkspaceRecordType.vlanGroup,
        WorkspaceRecordType.vlan, WorkspaceRecordType.interface, WorkspaceRecordType.ipAddressAssignment,
        WorkspaceRecordType.interfaceVLANMembership, CloudRecordNaming.auditRecordType,
        LocalRecordKind.auditEvent, CloudRecordNaming.workOrderRecordType,
        LocalRecordKind.workOrder, CloudRecordNaming.attachmentEvidenceBindingRecordType,
        CloudRecordNaming.floorPlanAssetBindingRecordType,
    ]
    static let csvExportRecordTypes: Set<String> = [
        WorkspaceRecordType.physicalTopology, LocalRecordKind.physicalTopology,
        WorkspaceRecordType.deviceType, WorkspaceRecordType.moduleTemplate, WorkspaceRecordType.device, WorkspaceRecordType.module, WorkspaceRecordType.port,
        WorkspaceRecordType.cable, WorkspaceRecordType.internalLink, WorkspaceRecordType.topologyTombstone,
        WorkspaceRecordType.workspaceHierarchy, WorkspaceRecordType.location, WorkspaceRecordType.rack,
        WorkspaceRecordType.hierarchyTombstone, WorkspaceRecordType.templatePlacementState, WorkspaceRecordType.rackPlacement,
        WorkspaceRecordType.floorPlanAnchor, WorkspaceRecordType.Legacy.floorPlanAnchor,
        WorkspaceRecordType.vrf, WorkspaceRecordType.prefix, LocalRecordKind.prefix, WorkspaceRecordType.ipAddressRecord,
        WorkspaceRecordType.vlanGroup, WorkspaceRecordType.vlan, WorkspaceRecordType.interface, WorkspaceRecordType.ipAddressAssignment,
        WorkspaceRecordType.interfaceVLANMembership,
    ]

    let records: [LocalMirrorRecord]
    let topology: PhysicalTopology
    let moduleTemplates: [ModuleTemplate]
    let hierarchy: WorkspaceHierarchy
    let placements: [RackPlacement]
    let rackReservations: [RackPlacementReservation]
    let anchors: [FloorPlanAnchor]
    let vrfs: [VRF]
    let prefixes: [Prefix]
    let addresses: [IPAddressRecord]
    let vlanGroups: [VLANGroup]
    let vlans: [VLAN]
    let interfaces: [Interface]
    let assignments: [IPAddressAssignment]
    let memberships: [InterfaceVLANMembership]
    let audits: [AuditEvent]
    let workOrders: [WorkOrder]
    let attachmentEvidenceBindings: [AttachmentEvidenceBindingRecord]
    let floorPlanAssetBindings: [FloorPlanAssetBindingRecord]
    let conflicts: [ReconciliationCase]
    let conflictCount: Int
    let syncState: LocalSyncState?
    let portStates: [ObjectID: PortState]
    let containmentIndex: [ObjectID: [String]]
    let siteIDIndex: [ObjectID: Set<ObjectID>]
    let siteNameIndex: [ObjectID: String]
    let plannedResourceKeys: Set<ResourceKey>
    let pendingResourceKeys: Set<ResourceKey>
    let conflictResourceKeys: Set<ResourceKey>

    init(
        records: [LocalMirrorRecord], conflicts: [ReconciliationCase], conflictResourceKeys: Set<ResourceKey>, conflictCount: Int, syncState: LocalSyncState?
    ) throws {
        try Task.checkCancellation()
        self.records = records
        let normalized = try ProductionMirrorDomainProjection(records: records)
        topology = normalized.topology
        moduleTemplates = normalized.moduleTemplates
        hierarchy = normalized.hierarchy
        placements = normalized.placements
        rackReservations = normalized.rackReservations
        anchors = normalized.anchors
        vrfs = try self.records.decoded(VRF.self, recordType: WorkspaceRecordType.vrf, expectedResourceKey: { .object($0.id) })
        prefixes = try self.records.decoded(Prefix.self, recordType: WorkspaceRecordType.prefix, expectedResourceKey: { .object($0.id) })
        addresses = try self.records.decoded(IPAddressRecord.self, recordType: WorkspaceRecordType.ipAddressRecord, expectedResourceKey: { .string($0.id) })
        vlanGroups = try self.records.decoded(VLANGroup.self, recordType: WorkspaceRecordType.vlanGroup, expectedResourceKey: { .object($0.id) })
        vlans = try self.records.decoded(VLAN.self, recordType: WorkspaceRecordType.vlan, expectedResourceKey: { .object($0.id) })
        interfaces = try self.records.decoded(Interface.self, recordType: WorkspaceRecordType.interface, expectedResourceKey: { .object($0.id) })
        assignments = try self.records.decoded(
            IPAddressAssignment.self, recordType: WorkspaceRecordType.ipAddressAssignment, expectedResourceKey: { .object($0.id) })
        memberships = try self.records.decoded(
            InterfaceVLANMembership.self, recordType: WorkspaceRecordType.interfaceVLANMembership,
            expectedResourceKey: { .object($0.id) })
        audits = try self.records.decoded(AuditEvent.self, recordType: CloudRecordNaming.auditRecordType, expectedResourceKey: { .object($0.id) })
        workOrders = try self.records.decoded(WorkOrder.self, recordType: CloudRecordNaming.workOrderRecordType, expectedResourceKey: { .object($0.id) })
        attachmentEvidenceBindings = try self.records.decoded(
            AttachmentEvidenceBindingRecord.self,
            recordType: CloudRecordNaming.attachmentEvidenceBindingRecordType,
            expectedResourceKey: { $0.resourceKey }
        )
        floorPlanAssetBindings = try self.records.decoded(
            FloorPlanAssetBindingRecord.self,
            recordType: CloudRecordNaming.floorPlanAssetBindingRecordType,
            expectedResourceKey: { $0.resourceKey }
        )
        self.conflicts = conflicts
        self.conflictCount = conflictCount
        self.syncState = syncState
        let indexes = try Self.makeIndexes(
            topology: topology, hierarchy: hierarchy, placements: placements, addresses: addresses, interfaces: interfaces,
            workOrders: workOrders, conflictResourceKeys: conflictResourceKeys
        )
        portStates = indexes.portStates
        containmentIndex = indexes.containment
        siteIDIndex = indexes.siteIDs
        siteNameIndex = indexes.siteNames
        plannedResourceKeys = indexes.plannedKeys
        pendingResourceKeys = indexes.pendingKeys
        self.conflictResourceKeys = indexes.conflictKeys
        try Task.checkCancellation()
    }
}
