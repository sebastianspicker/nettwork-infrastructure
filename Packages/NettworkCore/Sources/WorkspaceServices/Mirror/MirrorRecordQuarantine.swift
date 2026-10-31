import CloudSync
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

/// Read-path screening of individual mirror records. A record that is
/// oversized, undecodable or stored under a mismatched identity is dropped
/// from the browse projection and counted, so one damaged record no longer
/// takes every read screen of the workspace offline. Authoritative mutation
/// planners never use this screen: they keep rejecting the damaged record.
struct MirrorRecordQuarantine {
    static let maximumPayloadBytes = 1_048_576

    let accepted: [LocalMirrorRecord]
    let quarantinedCount: Int

    private typealias Check = @Sendable (LocalMirrorRecord) -> Bool

    init(screening records: [LocalMirrorRecord]) {
        var accepted: [LocalMirrorRecord] = []
        accepted.reserveCapacity(records.count)
        var quarantined = 0
        for record in records {
            if Self.isReadable(record) {
                accepted.append(record)
            } else {
                quarantined += 1
            }
        }
        self.accepted = accepted
        quarantinedCount = quarantined
    }

    private static func isReadable(_ record: LocalMirrorRecord) -> Bool {
        guard !record.isTombstone, let check = checks[record.recordType] else { return true }
        guard let payload = record.payload, payload.count <= maximumPayloadBytes else { return false }
        return check(record)
    }

    private static func check<T: Decodable & Sendable>(_ type: T.Type, key: @escaping @Sendable (T) -> ResourceKey?) -> Check {
        { record in
            guard let payload = record.payload, let value = try? CanonicalJSONCoding.decode(T.self, from: payload) else { return false }
            return key(value).map { $0 == record.resourceKey } ?? true
        }
    }

    private static func objectCheck<T: Decodable & Sendable & Identifiable>(_ type: T.Type) -> Check where T.ID == ObjectID {
        check(type) { .object($0.id) }
    }

    private static let checks: [String: Check] = {
        var result: [String: Check] = [:]
        func add(_ recordTypes: [String], _ check: @escaping Check) {
            for recordType in recordTypes { result[recordType] = check }
        }
        add([WorkspaceRecordType.physicalTopology, LocalRecordKind.physicalTopology], check(PhysicalTopology.self) { _ in nil })
        add([WorkspaceRecordType.workspaceHierarchy], check(WorkspaceHierarchy.self) { _ in nil })
        add([WorkspaceRecordType.templatePlacementState], check(TemplatePlacementState.self) { _ in nil })
        add([WorkspaceRecordType.deviceType], objectCheck(DeviceType.self))
        add([WorkspaceRecordType.moduleTemplate], objectCheck(ModuleTemplate.self))
        add([WorkspaceRecordType.device], objectCheck(Device.self))
        add([WorkspaceRecordType.module], objectCheck(Module.self))
        add([WorkspaceRecordType.port], objectCheck(Port.self))
        add([WorkspaceRecordType.cable], objectCheck(Cable.self))
        add([WorkspaceRecordType.internalLink], objectCheck(InternalLink.self))
        add([WorkspaceRecordType.topologyTombstone], objectCheck(TopologyTombstone.self))
        add([WorkspaceRecordType.location], objectCheck(Location.self))
        add([WorkspaceRecordType.rack], objectCheck(Rack.self))
        add([WorkspaceRecordType.hierarchyTombstone], objectCheck(HierarchyTombstone.self))
        add([WorkspaceRecordType.rackPlacement], check(RackPlacement.self) { .rackPlacement(deviceID: $0.deviceID) })
        add([WorkspaceRecordType.floorPlanAnchor, WorkspaceRecordType.Legacy.floorPlanAnchor], objectCheck(FloorPlanAnchor.self))
        add([WorkspaceRecordType.vrf], objectCheck(VRF.self))
        add([WorkspaceRecordType.prefix, LocalRecordKind.prefix], objectCheck(Prefix.self))
        add([WorkspaceRecordType.ipAddressRecord], check(IPAddressRecord.self) { .string($0.id) })
        add([WorkspaceRecordType.vlanGroup], objectCheck(VLANGroup.self))
        add([WorkspaceRecordType.vlan], objectCheck(VLAN.self))
        add([WorkspaceRecordType.interface], objectCheck(Interface.self))
        add([WorkspaceRecordType.ipAddressAssignment], objectCheck(IPAddressAssignment.self))
        add([WorkspaceRecordType.interfaceVLANMembership], objectCheck(InterfaceVLANMembership.self))
        add([CloudRecordNaming.auditRecordType, LocalRecordKind.auditEvent], objectCheck(AuditEvent.self))
        add([CloudRecordNaming.workOrderRecordType, LocalRecordKind.workOrder], objectCheck(WorkOrder.self))
        add(
            [CloudRecordNaming.attachmentEvidenceBindingRecordType],
            check(AttachmentEvidenceBindingRecord.self) { $0.resourceKey })
        add(
            [CloudRecordNaming.floorPlanAssetBindingRecordType],
            check(FloorPlanAssetBindingRecord.self) { $0.resourceKey })
        return result
    }()
}

extension MirrorProjection {
    /// Builds the browse projection, quarantining individual damaged records
    /// when the strict build rejects the mirror. The strict path is tried first
    /// so a healthy mirror pays no extra decode cost.
    static func quarantining(
        records: [LocalMirrorRecord], conflicts: [ReconciliationCase], conflictResourceKeys: Set<ResourceKey>, conflictCount: Int,
        syncState: LocalSyncState?
    ) throws -> MirrorProjection {
        do {
            return try MirrorProjection(
                records: records, conflicts: conflicts, conflictResourceKeys: conflictResourceKeys, conflictCount: conflictCount, syncState: syncState)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let screened = MirrorRecordQuarantine(screening: records)
            guard screened.quarantinedCount > 0 else { throw error }
            do {
                return try MirrorProjection(
                    records: screened.accepted, conflicts: conflicts, conflictResourceKeys: conflictResourceKeys, conflictCount: conflictCount,
                    syncState: syncState, quarantinedRecordCount: screened.quarantinedCount)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ProductionAdapterError.quarantinedRecordsBlockProjection(screened.quarantinedCount)
            }
        }
    }
}
