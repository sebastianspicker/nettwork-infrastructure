import CloudSync
import CryptoKit
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

struct ProductionMutationMaterial: Sendable {
    let saves: [AuthoritativeRecordSave]
    let tombstones: [AuthoritativeTombstone]
    /// The conditional-write state captured while deriving each emitted save
    /// or tombstone. A missing source is represented by `.mustNotExist`.
    let touchedPreconditions: [ResourceKey: MutationPrecondition]
    /// Records consulted while deriving the result but not written by it.
    /// Keeping these immutable makes the material's complete input snapshot
    /// auditable, even though the current mutation envelope can condition only
    /// records it writes.
    let readOnlyDependencies: [AuthoritativeReadAssertion]

    init(
        saves: [AuthoritativeRecordSave] = [], tombstones: [AuthoritativeTombstone] = [],
        touchedPreconditions: [ResourceKey: MutationPrecondition] = [:], readOnlyDependencies: [AuthoritativeReadAssertion] = []
    ) {
        self.saves = saves
        self.tombstones = tombstones
        self.touchedPreconditions = touchedPreconditions
        self.readOnlyDependencies = readOnlyDependencies
    }
}

protocol ProductionDraftSemanticValidating: Sendable {
    /// Validates the complete desired operation payload against a current,
    /// account-scoped authoritative snapshot. Returning an issue prevents any
    /// reservation or CloudKit mutation.
    func issues(for draft: WorkOrderDraft, in namespace: PersistenceNamespace) async throws -> [String]
}

protocol ProductionCompletionMaterializing: Sendable {
    /// Converts reviewed planned operations into exact record saves and
    /// tombstones. It must rerun all topology/IPAM/template invariants against
    /// current records before returning.
    func materializeCompletion(of workOrder: WorkOrder, at occurredAt: Date, in namespace: PersistenceNamespace) async throws -> ProductionMutationMaterial
}

public protocol ProductionCorrectiveDraftBuilding: Sendable {
    func correctiveDraft(for reconciliationID: ObjectID, actorID: String, in namespace: PersistenceNamespace) async throws -> WorkOrderDraft
}

public protocol ProductionImmutableAuditExporting: Sendable {
    /// Creates the export only in an app-private staging location. The
    /// capability cannot be presented to callers until `publishAudit` commits
    /// it after a final authority revalidation.
    func prepareAudit(operationID: ObjectID, in namespace: PersistenceNamespace) async throws -> ProductionStagedAuditExport
    /// Atomically promotes a previously private staged export to its caller
    /// visible destination.
    func publishAudit(_ staged: ProductionStagedAuditExport, in namespace: PersistenceNamespace) async throws -> URL
    func abortAudit(_ staged: ProductionStagedAuditExport, in namespace: PersistenceNamespace) async
}

/// Opaque, app-private export capability. Exporters must keep the represented
/// bytes in a private staging area until the authority publishes this token.
public struct ProductionStagedAuditExport: Sendable {
    let capabilityID: ObjectID

    init(capabilityID: ObjectID) {
        self.capabilityID = capabilityID
    }
}

public protocol ProductionStagedWorkOrderDraftStoring: Sendable {
    func store(_ draft: WorkOrderDraft, in namespace: PersistenceNamespace) async
    func draft(id: ObjectID, in namespace: PersistenceNamespace) async -> WorkOrderDraft?
}

public actor SessionWorkOrderDraftStore: ProductionStagedWorkOrderDraftStoring {
    private var drafts: [PersistenceNamespace: [ObjectID: WorkOrderDraft]] = [:]

    public init() {}

    public func store(_ draft: WorkOrderDraft, in namespace: PersistenceNamespace) {
        drafts[namespace, default: [:]][draft.id] = draft
    }

    public func draft(id: ObjectID, in namespace: PersistenceNamespace) -> WorkOrderDraft? {
        drafts[namespace]?[id]
    }
}

public struct ProductionWorkOrderPolicy: Sendable {
    let policyVersion: String
    let reservationLifetime: TimeInterval

    public init(policyVersion: String, reservationLifetime: TimeInterval) throws {
        let version = policyVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, reservationLifetime.isFinite, reservationLifetime > 0 else {
            throw ProductionFeatureMutationAuthorityError.invalidPolicy
        }
        self.policyVersion = version
        self.reservationLifetime = reservationLifetime
    }
}

enum ProductionFeatureMutationAuthorityError: Error, Equatable, Sendable {
    case invalidPolicy
    case namespaceMismatch
    case invalidDraft([String])
    case workOrderMissing
    case malformedWorkOrder
    case invalidReservation
    case reservationNotAcknowledged
    case invalidCancellationRequestState
    case cancellationNotRequested
    case invalidCancellationReleaseAuthorization
    case receiptMismatch
    case unsupportedDraft
    case missingMaterialPrecondition(ResourceKey)
    case malformedMaterialPrecondition(ResourceKey)
    case materialOutsideReservation(ResourceKey)
    case workspaceInactive
}

/// Production workflow orchestration. Presentation authorization is used only
/// as an assertion; every privileged method resolves the live Cloud account,
/// actor, installation, session, role, and active lease through
/// `ProductionSessionAuthorizer` before constructing one D06 mutation.
@MainActor
public final class ProductionFeatureMutationAuthority: ProductionFeatureMutationAuthorizing, ProductionFloorPlanWorkOrderStaging {
    let account: AccountContext
    let sessionAuthorizer: ProductionSessionAuthorizer
    let exactRecords: any CloudExactRecordReading
    let mutations: any AuthoritativeMutationRepository
    let acknowledgements: CloudReservationAcknowledgementService
    let semanticValidator: any ProductionDraftSemanticValidating
    let completionMaterializer: any ProductionCompletionMaterializing
    let correctiveBuilder: any ProductionCorrectiveDraftBuilding
    let auditExporter: any ProductionImmutableAuditExporting
    let draftStore: any ProductionStagedWorkOrderDraftStoring
    let policy: ProductionWorkOrderPolicy

    init(
        account: AccountContext, sessionAuthorizer: ProductionSessionAuthorizer, exactRecords: any CloudExactRecordReading,
        mutations: any AuthoritativeMutationRepository, acknowledgements: CloudReservationAcknowledgementService,
        semanticValidator: any ProductionDraftSemanticValidating, completionMaterializer: any ProductionCompletionMaterializing,
        correctiveBuilder: any ProductionCorrectiveDraftBuilding, auditExporter: any ProductionImmutableAuditExporting,
        draftStore: any ProductionStagedWorkOrderDraftStoring, policy: ProductionWorkOrderPolicy
    ) {
        self.account = account
        self.sessionAuthorizer = sessionAuthorizer
        self.exactRecords = exactRecords
        self.mutations = mutations
        self.acknowledgements = acknowledgements
        self.semanticValidator = semanticValidator
        self.completionMaterializer = completionMaterializer
        self.correctiveBuilder = correctiveBuilder
        self.auditExporter = auditExporter
        self.draftStore = draftStore
        self.policy = policy
    }
}
