import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

/// An operator-selected corrective command. The selection is bound to the
/// exact unresolved case the operator reviewed; this boundary never derives a
/// command from reconciliation snapshot bytes.
struct CorrectiveResolution: Hashable, Sendable {
    enum Operation: Hashable, Sendable {
        case topology(TopologyCommand)
        case ipam(PlannedIPAMOperation)
        case template(kind: PlannedTemplateChangeKind, target: DeviceType, sourceTemplateID: ObjectID?, migrations: [DeviceTemplateMigrationPlan])
        case moduleTemplate(kind: PlannedTemplateChangeKind, target: ModuleTemplate, sourceTemplateID: ObjectID?)
        case deviceDecommission(PlannedDeviceDecommission)
        case floorPlan(PlannedFloorPlanOperation)
        case hierarchy(PlannedHierarchyOperation)
    }

    let reconciliationID: ObjectID
    let namespace: PersistenceNamespace
    let reconciliationOperationID: ObjectID
    let detectedAt: Date
    let resourceKeys: Set<ResourceKey>
    let actorID: String
    let title: String
    let ticket: String
    let notes: String
    let operation: Operation
}

/// The presentation layer (or another operator-facing boundary) supplies the
/// action explicitly selected for the displayed reconciliation case.
protocol CorrectiveResolutionProviding: Sendable {
    func resolution(for reconciliationCase: ReconciliationCase, actorID: String, in namespace: PersistenceNamespace) async throws -> CorrectiveResolution
}

enum ProductionCorrectiveDraftBuilderError: Error, Equatable, Sendable {
    case namespaceMismatch
    case reconciliationCaseMissing
    case securityCase
    case staleResolution
    case invalidResolution
}

/// Builds a draft from an explicit, typed operator resolution. Reconciliation
/// snapshots remain opaque evidence and are used only to bind the selected
/// resolution to the still-unresolved case.
actor ProductionCorrectiveDraftBuilder: ProductionCorrectiveDraftBuilding {
    private let persistence: SwiftDataPersistenceStore
    private let resolutionProvider: any CorrectiveResolutionProviding

    init(persistence: SwiftDataPersistenceStore, resolutionProvider: any CorrectiveResolutionProviding) {
        self.persistence = persistence
        self.resolutionProvider = resolutionProvider
    }

    func correctiveDraft(for reconciliationID: ObjectID, actorID: String, in namespace: PersistenceNamespace) async throws -> WorkOrderDraft {
        let reconciliationCase = try await loadCase(id: reconciliationID, in: namespace)
        guard !reconciliationCase.isSecurityEvent else {
            throw ProductionCorrectiveDraftBuilderError.securityCase
        }

        let resolution = try await resolutionProvider.resolution(for: reconciliationCase, actorID: actorID, in: namespace)
        try validate(resolution, binds: reconciliationCase, actorID: actorID, namespace: namespace)

        // The provider may have awaited operator input. Re-read the unresolved
        // case before returning a draft so a resolved or replaced case cannot
        // be acted on with a stale selection.
        let latest = try await persistence.unresolvedCases(in: namespace)
            .first(where: { $0.id == reconciliationID })
        guard latest == reconciliationCase else {
            throw ProductionCorrectiveDraftBuilderError.staleResolution
        }

        let planned = plannedOperation(for: resolution.operation)
        return WorkOrderDraft(
            title: resolution.title,
            kind: workOrderKind(for: resolution.operation),
            ticket: resolution.ticket,
            notes: resolution.notes,
            resourceKeys: try operationResourceKeys(planned),
            operations: [planned]
        )
    }

    private func loadCase(id: ObjectID, in namespace: PersistenceNamespace) async throws -> ReconciliationCase {
        guard
            let reconciliationCase = try await persistence.unresolvedCases(in: namespace)
                .first(where: { $0.id == id })
        else {
            throw ProductionCorrectiveDraftBuilderError.reconciliationCaseMissing
        }
        guard reconciliationCase.namespace == namespace else {
            throw ProductionCorrectiveDraftBuilderError.namespaceMismatch
        }
        return reconciliationCase
    }

    private func validate(
        _ resolution: CorrectiveResolution, binds reconciliationCase: ReconciliationCase, actorID: String, namespace: PersistenceNamespace
    ) throws {
        guard resolution.namespace == namespace,
            reconciliationCase.namespace == namespace
        else {
            throw ProductionCorrectiveDraftBuilderError.namespaceMismatch
        }
        guard resolution.reconciliationID == reconciliationCase.id,
            resolution.reconciliationOperationID == reconciliationCase.operationID,
            resolution.detectedAt == reconciliationCase.detectedAt,
            resolution.resourceKeys == reconciliationCase.resourceKeys,
            resolution.actorID == actorID
        else {
            throw ProductionCorrectiveDraftBuilderError.staleResolution
        }
        guard !resolution.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !resolution.ticket.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !actorID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ProductionCorrectiveDraftBuilderError.invalidResolution
        }
        if case .topology(.remove(_)) = resolution.operation {
            throw ProductionCorrectiveDraftBuilderError.invalidResolution
        }
    }

    private func plannedOperation(for operation: CorrectiveResolution.Operation) -> PlannedWorkOperation {
        switch operation {
        case .topology(let command):
            return .topology(command)
        case .ipam(let value):
            return .ipam(value)
        case let .template(kind, target, sourceTemplateID, migrations):
            return .template(kind: kind, target: target, sourceTemplateID: sourceTemplateID, migrations: migrations)
        case let .moduleTemplate(kind, target, sourceTemplateID):
            return .moduleTemplate(kind: kind, target: target, sourceTemplateID: sourceTemplateID)
        case .deviceDecommission(let value):
            return .deviceDecommission(value)
        case .floorPlan(let value):
            return .floorPlan(value)
        case .hierarchy(let value):
            return .hierarchy(value)
        }
    }

    private func workOrderKind(for operation: CorrectiveResolution.Operation) -> WorkOrderKind {
        switch operation {
        case .topology(let command): return topologyWorkOrderKind(command)
        case .ipam:
            return .ipam
        case .template:
            return .device
        case .moduleTemplate:
            return .device
        case .deviceDecommission:
            return .device
        case .floorPlan:
            return .floorPlan
        case .hierarchy:
            return .hierarchy
        }
    }

    private func topologyWorkOrderKind(_ command: TopologyCommand) -> WorkOrderKind {
        switch command {
        case .connect: .connect
        case .disconnect: .disconnect
        case .move: .move
        case .install, .remove, .markUnavailable: .device
        }
    }

    private func operationResourceKeys(_ operation: PlannedWorkOperation) throws -> Set<ResourceKey> {
        switch operation {
        case .topology(let command): return topologyResourceKeys(command)
        case .ipam(let value): return ipamResourceKeys(value)
        case let .template(_, target, sourceTemplateID, migrations):
            return templateResourceKeys(target: target, sourceTemplateID: sourceTemplateID, migrations: migrations)
        case let .moduleTemplate(_, target, sourceTemplateID):
            return moduleTemplateResourceKeys(target: target, sourceTemplateID: sourceTemplateID)
        case .deviceDecommission(let value):
            return value.resourceKeys
        case .floorPlan(let value):
            return value.resourceKeys
        case .hierarchy(let value):
            return value.resourceKeys
        case .device:
            throw ProductionCorrectiveDraftBuilderError.invalidResolution
        }
    }

    private func templateResourceKeys(target: DeviceType, sourceTemplateID: ObjectID?, migrations: [DeviceTemplateMigrationPlan]) -> Set<ResourceKey> {
        var keys = moduleTemplateResourceKeys(target: target, sourceTemplateID: sourceTemplateID)
        for migration in migrations {
            keys.insert(.object(migration.deviceID))
            for impact in migration.portImpacts {
                if let currentPort = impact.currentPort { keys.insert(.object(currentPort.id)) }
                if let desiredPort = impact.desiredPort { keys.insert(.object(desiredPort.id)) }
                keys.formUnion(impact.connectedCableIDs.map { .object($0) })
            }
        }
        return keys
    }

    private func moduleTemplateResourceKeys<T: Identifiable>(target: T, sourceTemplateID: ObjectID?) -> Set<ResourceKey> where T.ID == ObjectID {
        var keys: Set<ResourceKey> = [.object(target.id)]
        if let sourceTemplateID { keys.insert(.object(sourceTemplateID)) }
        return keys
    }

    private func topologyResourceKeys(_ command: TopologyCommand) -> Set<ResourceKey> {
        switch command {
        case .connect(let value): return [.object(value.cable.id), .object(value.cable.endpointA), .object(value.cable.endpointB)]
        case .disconnect(let value): return [.object(value.cableID)]
        case .move(let value): return [.object(value.cableID), .object(value.endpointA), .object(value.endpointB)]
        case .install(let value): return Set([.object(value.device.id)] + value.modules.map { .object($0.id) } + value.ports.map { .object($0.id) })
        case .remove(let value): return [.object(value.deviceID)]
        case .markUnavailable(let value): return [.object(value.portID)]
        }
    }

    private func ipamResourceKeys(_ value: PlannedIPAMOperation) -> Set<ResourceKey> {
        switch value {
        case let .prefixLayout(vrf, _, current, desired):
            return Set([.object(vrf.id)] + (current + desired).map { .object($0.id) })
        case let .addressAssignment(assignments):
            return addressAssignmentResourceKeys(assignments)
        case let .vlanMembership(memberships):
            return vlanMembershipResourceKeys(memberships)
        case let .legacyAddressAssignment(addressKey, interfaceID):
            return [addressKey, .object(interfaceID)]
        case let .legacyVLANMembership(interfaceID, vlanID, _):
            return [.object(interfaceID), .object(vlanID)]
        }
    }

    private func addressAssignmentResourceKeys(_ assignments: InterfaceAddressAssignmentSet) -> Set<ResourceKey> {
        var keys: Set<ResourceKey> = [.object(assignments.revisionVRF.id), .object(assignments.interfaceID)]
        for assignment in assignments.currentAssignments + assignments.desiredAssignments {
            keys.formUnion([.object(assignment.id), .string(assignment.addressID), .object(assignment.interfaceID)])
        }
        return keys
    }

    private func vlanMembershipResourceKeys(_ memberships: InterfaceVLANMembershipSet) -> Set<ResourceKey> {
        var keys: Set<ResourceKey> = [.object(memberships.revisionVRF.id), .object(memberships.interfaceID)]
        for membership in memberships.currentMemberships + memberships.desiredMemberships {
            keys.formUnion([.object(membership.id), .object(membership.interfaceID), .object(membership.vlanID)])
        }
        return keys
    }
}
