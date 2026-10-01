import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

enum ProductionMutationPlannerError: Error, Equatable, Sendable {
    case namespaceMismatch
    case malformedMirrorRecord(ResourceKey)
    case missingTopologyObject(ResourceKey)
    case missingHierarchyObject(ResourceKey)
    case missingIPAMObject(ResourceKey)
    case staleIPAMRelationshipSet(ResourceKey)
    case invalidIPAMRelationshipSet(ResourceKey)
    case missingFloorPlanAnchor(ResourceKey)
    case staleDeviceDecommission(ResourceKey)
    case legacyIntentRequiresReconciliation
    case invalidHierarchyOperation
    case unsupportedGenericDeviceOperation
    case duplicateMutation(ResourceKey)
    case missingMirrorPrecondition(ResourceKey)
}

/// Uses the lease-gated, verified mirror as the complete candidate snapshot.
/// The returned saves are still committed with exact CloudKit preconditions by
/// `ProductionFeatureMutationAuthority`; this planner is never an authority by
/// itself.
actor SwiftDataProductionMutationPlanner: ProductionDraftSemanticValidating, ProductionCompletionMaterializing {
    private let persistence: SwiftDataPersistenceStore
    private let account: AccountContext

    init(persistence: SwiftDataPersistenceStore, account: AccountContext) {
        self.persistence = persistence
        self.account = account
    }

    func issues(for draft: WorkOrderDraft, in namespace: PersistenceNamespace) async throws -> [String] {
        do {
            _ = try await plan(operations: draft.operations, workOrderID: draft.id, in: namespace)
            return []
        } catch {
            return [String(describing: error)]
        }
    }

    func materializeCompletion(of workOrder: WorkOrder, at occurredAt: Date, in namespace: PersistenceNamespace) async throws -> ProductionMutationMaterial {
        try await plan(operations: workOrder.plannedOperations, workOrderID: workOrder.id, occurredAt: occurredAt, in: namespace)
    }

    private func plan(
        operations: [PlannedWorkOperation], workOrderID: ObjectID, occurredAt: Date = .distantPast, in namespace: PersistenceNamespace
    ) async throws -> ProductionMutationMaterial {
        guard namespace == account.namespace else {
            throw ProductionMutationPlannerError.namespaceMismatch
        }
        let records = try await persistence.authoritativePlanningRecords(in: namespace)
        let inputs = try materializationInputs(from: records)
        var snapshot = try Snapshot(records: inputs.records)
        var changes = ChangeAccumulator(deletedAt: occurredAt, sourcePreconditions: inputs.preconditions, sourceAssertions: inputs.assertions)

        for (index, operation) in operations.enumerated() {
            try apply(operation, operationIndex: index, workOrderID: workOrderID, snapshot: &snapshot, changes: &changes)
        }
        try validate(snapshot)
        return try changes.material()
    }
}
