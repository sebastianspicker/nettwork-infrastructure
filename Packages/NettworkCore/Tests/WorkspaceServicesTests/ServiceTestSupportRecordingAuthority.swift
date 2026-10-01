import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Records which mutation-authority entry point was called and with which
/// namespace. Adapters must delegate privileged work here unchanged.
@MainActor
final class RecordingMutationAuthority: ProductionFeatureMutationAuthorizing {
    private(set) var calls: [(name: String, namespace: PersistenceNamespace)] = []
    let stagedID = ObjectID()

    private func record(_ name: String, _ namespace: PersistenceNamespace) { calls.append((name, namespace)) }

    func validateDraft(_: WorkOrderDraft, authorization _: OperationsAuthorization, in namespace: PersistenceNamespace) async throws -> WorkOrderValidation {
        record("validateDraft", namespace)
        return WorkOrderValidation(isValid: false, exactIntentDigest: nil, issues: ["recorded"])
    }
    func stageTopology(_: TopologyWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        record("stageTopology", namespace)
        return stagedID
    }
    func stageTemplate(_: TemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        record("stageTemplate", namespace)
        return stagedID
    }
    func stageModuleTemplate(_: ModuleTemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        record("stageModuleTemplate", namespace)
        return stagedID
    }
    func stageIPAM(_: IPAMWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        record("stageIPAM", namespace)
        return stagedID
    }
    func stagedDraft(id _: ObjectID, in namespace: PersistenceNamespace) async throws -> WorkOrderDraft {
        record("stagedDraft", namespace)
        throw ServiceTestError(reason: "recorded")
    }
    func reserve(
        _: WorkOrderDraft, authorization _: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation {
        record("reserve", namespace)
        throw ServiceTestError(reason: "recorded")
    }
    func refreshReservation(
        _: WorkOrderReservationPresentation, authorization _: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation {
        record("refreshReservation", namespace)
        throw ServiceTestError(reason: "recorded")
    }
    func requestApproval(for _: ObjectID, authorization _: OperationsAuthorization, in namespace: PersistenceNamespace) async throws {
        record("requestApproval", namespace)
    }
    func beginExecution(
        workOrderID _: ObjectID, reservationID _: ObjectID, intentDigest _: IntentDigest, authorization _: OperationsAuthorization,
        in namespace: PersistenceNamespace
    ) async throws {
        record("beginExecution", namespace)
    }
    func complete(workOrderID _: ObjectID, evidence _: [EvidenceHash], authorization _: OperationsAuthorization, in namespace: PersistenceNamespace)
        async throws
    {
        record("complete", namespace)
    }
    func requestCancellation(
        workOrderID _: ObjectID, reason _: String, physicalStatus _: CancellationPhysicalStatus, authorization _: OperationsAuthorization,
        in namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation {
        record("requestCancellation", namespace)
        throw ServiceTestError(reason: "recorded")
    }
    func resolveCancellation(
        workOrderID _: ObjectID, reason _: String, releaseAuthorization _: CancellationReleaseAuthorization, authorization _: OperationsAuthorization,
        in namespace: PersistenceNamespace
    ) async throws {
        record("resolveCancellation", namespace)
    }
    func createCorrectiveWorkOrder(
        for _: ObjectID, authorization _: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> ObjectID {
        record("createCorrectiveWorkOrder", namespace)
        return stagedID
    }
    func exportImmutableAudit(authorization _: AuthorizedOperationContext, in namespace: PersistenceNamespace) async throws -> URL {
        record("exportImmutableAudit", namespace)
        return URL(fileURLWithPath: "/dev/null")
    }
}
