import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

actor StubSemanticValidator: ProductionDraftSemanticValidating {
    private var result: [String] = []
    private(set) var callCount = 0

    func setIssues(_ issues: [String]) { result = issues }

    func issues(for _: WorkOrderDraft, in _: PersistenceNamespace) async throws -> [String] {
        callCount += 1
        return result
    }
}

actor StubCompletionMaterializer: ProductionCompletionMaterializing {
    private var material = ProductionMutationMaterial()

    func setMaterial(_ material: ProductionMutationMaterial) { self.material = material }

    func materializeCompletion(of _: WorkOrder, at _: Date, in _: PersistenceNamespace) async throws -> ProductionMutationMaterial { material }
}

struct StubCorrectiveBuilder: ProductionCorrectiveDraftBuilding {
    func correctiveDraft(for _: ObjectID, actorID _: String, in _: PersistenceNamespace) async throws -> WorkOrderDraft {
        throw ServiceTestError(reason: "no reconciliation cases")
    }
}

/// Records the prepare → publish/abort sequence of the audit export
/// capability and can run a hook between preparation and publication.
actor RecordingAuditExporter: ProductionImmutableAuditExporting {
    private(set) var events: [String] = []
    private var afterPrepare: (@Sendable () async -> Void)?

    func setAfterPrepare(_ hook: @escaping @Sendable () async -> Void) { afterPrepare = hook }

    func prepareAudit(operationID _: ObjectID, in _: PersistenceNamespace) async throws -> ProductionStagedAuditExport {
        events.append("prepare")
        await afterPrepare?()
        return ProductionStagedAuditExport(capabilityID: ObjectID())
    }

    func publishAudit(_: ProductionStagedAuditExport, in _: PersistenceNamespace) async throws -> URL {
        events.append("publish")
        return URL(fileURLWithPath: "/dev/null")
    }

    func abortAudit(_: ProductionStagedAuditExport, in _: PersistenceNamespace) async {
        events.append("abort")
    }
}

/// A production mutation authority wired to the in-memory Cloud server and a
/// live session. The workspace sentinel starts active. By default draft
/// validation and completion material are stubbed; `planned` instead wires
/// the SwiftData planner over a mirror of the topology and hierarchy fixtures
/// whose sentinel matches the server's exactly, and makes the server enforce
/// every commit precondition.
@MainActor
struct MutationAuthorityHarness {
    let session: SessionHarness
    let server: FakeCloudServer
    let validator: StubSemanticValidator
    let materializer: StubCompletionMaterializer
    let exporter: RecordingAuditExporter
    let authority: ProductionFeatureMutationAuthority
    let topology = TopologyFixture()

    static let reservationLifetime: TimeInterval = 3_600

    static func make(role: OfficialClientRole = .administrator, planned: Bool = false) async throws -> MutationAuthorityHarness {
        let session = try await SessionHarness.make(role: role)
        let server = FakeCloudServer()
        let lifecycle = ServiceFixture.activeLifecycle()
        try await server.putSentinel(session.namespace, lifecycle: lifecycle, tag: planned ? "workspace-active" : "workspace-sentinel")
        let validator = StubSemanticValidator()
        let materializer = StubCompletionMaterializer()
        var planner: SwiftDataProductionMutationPlanner?
        if planned {
            let store = try ServiceFixture.makeStore()
            let mirror = try TopologyFixture().records(in: session.namespace) + HierarchyFixture().records(in: session.namespace)
            let sentinel = try ServiceFixture.sentinelMirror(session.namespace, lifecycle: lifecycle)
            try await ServiceFixture.seed(store, namespace: session.namespace, records: mirror + [sentinel])
            planner = SwiftDataProductionMutationPlanner(persistence: store, account: session.account)
            await server.enforcePreconditions()
        }
        let exporter = RecordingAuditExporter()
        let authority = ProductionFeatureMutationAuthority(
            account: session.account, sessionAuthorizer: session.authorizer, exactRecords: server, mutations: server,
            acknowledgements: CloudReservationAcknowledgementService(exactRecords: server, mutations: server),
            semanticValidator: planner ?? validator, completionMaterializer: planner ?? materializer, correctiveBuilder: StubCorrectiveBuilder(),
            auditExporter: exporter, draftStore: SessionWorkOrderDraftStore(),
            policy: try ProductionWorkOrderPolicy(policyVersion: "service-test-policy", reservationLifetime: reservationLifetime))
        return MutationAuthorityHarness(
            session: session, server: server, validator: validator, materializer: materializer, exporter: exporter, authority: authority)
    }

    var namespace: PersistenceNamespace { session.namespace }
    var presentation: OperationsAuthorization { session.presentation }

    /// A structurally valid connect draft whose resource set exactly covers
    /// the cable and both endpoints.
    func connectDraft(ticket: String = "CHG-100") -> WorkOrderDraft {
        let operation = PlannedWorkOperation.topology(.connect(ConnectTopologyCommand(cable: topology.patch())))
        return WorkOrderDraft(
            title: "Patch switch to panel", kind: .connect, ticket: ticket, resourceKeys: operation.productionResourceKeys, operations: [operation])
    }

    /// A draft with exactly one reserved resource. Seeded server work orders
    /// use it because a multi-member `Set<ResourceKey>` has no stable
    /// encoding order, which the authority's canonical decoding rejects.
    func singleResourceDraft(ticket: String = "CHG-200") -> WorkOrderDraft {
        let operation = PlannedWorkOperation.topology(
            .markUnavailable(MarkPortUnavailableTopologyCommand(portID: topology.spareSwitchPort.id, isUnavailable: true)))
        return WorkOrderDraft(
            title: "Mark spare port unavailable", kind: .device, ticket: ticket, resourceKeys: operation.productionResourceKeys, operations: [operation])
    }

    func expectedDigest(for draft: WorkOrderDraft) throws -> IntentDigest {
        try CanonicalWorkIntent(
            workOrderID: draft.id, kind: draft.kind, creatorID: session.actor.cloudKitUserRecordName,
            ticket: draft.ticket.trimmingCharacters(in: .whitespacesAndNewlines), notes: nil,
            operations: draft.operations, resourceKeys: draft.resourceKeys, evidenceHashes: draft.evidence
        ).digest()
    }

    func reserve(_ draft: WorkOrderDraft) async throws -> WorkOrderReservationPresentation {
        try await authority.reserve(draft, authorization: presentation, in: namespace)
    }

    /// Publishes an acknowledged reservation for `draft` directly on the
    /// server, advanced to `status`, with whole-second dates. Lifecycle tests
    /// use this instead of `reserve` so they never depend on a commit path.
    @discardableResult
    func seedReservedOrder(
        _ draft: WorkOrderDraft, status: WorkOrderStatus = .reserved, expiresAt: Date = .distantFuture
    ) async throws -> (order: WorkOrder, presentation: WorkOrderReservationPresentation) {
        let owner = session.actor.cloudKitUserRecordName
        let digest = try expectedDigest(for: draft)
        let reservation = WorkOrderReservation(ownerID: owner, resourceKeys: draft.resourceKeys)
        let draftOrder = WorkOrder(
            id: draft.id, kind: draft.kind, title: draft.title, creatorID: owner, ticket: draft.ticket.trimmingCharacters(in: .whitespacesAndNewlines),
            plannedOperations: draft.operations, intentDigest: digest, reservation: reservation)
        let context = WorkOrderTransitionContext(actorID: owner, at: ServiceFixture.epoch)
        let acknowledgement = CloudKitAcknowledgement(
            workspaceZone: namespace.workspaceZone, cloudKitAccountRecordName: owner, sessionGeneration: session.actor.sessionGeneration,
            reservationID: reservation.id, workOrderID: draft.id, ownerID: owner, resourceKeys: draft.resourceKeys, intentDigest: digest,
            systemFields: Data([1]), changeTag: "reservation-ack", acknowledgedAt: ServiceFixture.epoch, expiresAt: expiresAt)
        var order = try WorkOrderStateMachine.acknowledgeReservation(
            try WorkOrderStateMachine.transition(draftOrder, to: .reserved, context: context), acknowledgement: acknowledgement,
            observedAt: ServiceFixture.epoch)
        if [.approved, .executing, .cancellationRequested].contains(status) {
            order = try WorkOrderStateMachine.transition(order, to: .approved, context: context)
        }
        if status == .executing {
            order = try WorkOrderStateMachine.transition(order, to: .executing, context: context)
        }
        if status == .cancellationRequested {
            order = try WorkOrderStateMachine.requestCancellation(order, reason: "Room closed", by: owner, at: ServiceFixture.epoch)
        }
        await server.put(
            CloudExactRecordSnapshot(
                workspaceZone: namespace.workspaceZone, resourceKey: .object(order.id), recordType: CloudRecordNaming.workOrderRecordType,
                schemaVersion: CloudRecordNaming.schemaVersion, payload: try CloudDeterministicCoding.encode(order),
                exactPrecondition: ServiceFixture.exact("work-order"), serverModifiedAt: ServiceFixture.epoch))
        let presentation = WorkOrderReservationPresentation(
            id: reservation.id, workOrderID: order.id, exactIntentDigest: digest, resourceKeys: draft.resourceKeys, expiresAt: expiresAt,
            confirmation: .confirmed, workOrderStatus: order.status, cancellationRequestID: order.cancellationHistory.last?.id)
        return (order, presentation)
    }

    func serverWorkOrder(_ id: ObjectID) async throws -> WorkOrder {
        guard let snapshot = await server.snapshot(for: .object(id)) else { throw ServiceTestError(reason: "work order missing") }
        return try CloudDeterministicCoding.decode(WorkOrder.self, from: snapshot.payload)
    }

    func releaseScope(for reservation: WorkOrderReservationPresentation, sessionID: String = "session-1") throws -> CancellationReleaseScope {
        guard let requestID = reservation.cancellationRequestID else { throw ServiceTestError(reason: "no cancellation request") }
        return CancellationReleaseScope(
            workspaceZone: namespace.workspaceZone, workOrderID: reservation.workOrderID, reservationID: reservation.id, cancellationRequestID: requestID,
            actorID: session.actor.cloudKitUserRecordName, installationID: session.actor.installationID, sessionID: sessionID,
            sessionGeneration: session.actor.sessionGeneration, issuedAt: Date.now.addingTimeInterval(-60), expiresAt: Date.now.addingTimeInterval(600))
    }
}
