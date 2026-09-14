import CloudSync
import ContentSafety
import CryptoKit
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

/// Bounded, account-scoped access to already-verified local-mirror records.
/// The persistence implementation must validate the active namespace lease
/// before returning records and must retain tombstones for callers that need
/// to surface their effect in a read model.
protocol ScopedMirrorRecordEnumerating: Sendable {
    func records(in namespace: PersistenceNamespace, recordTypes: Set<String>, limitPerType: Int) async throws -> [LocalMirrorRecord]
}

actor SwiftDataMirrorRecordEnumerator: ScopedMirrorRecordEnumerating {
    let persistence: SwiftDataPersistenceStore

    init(persistence: SwiftDataPersistenceStore) { self.persistence = persistence }

    func records(in namespace: PersistenceNamespace, recordTypes: Set<String>, limitPerType: Int) async throws -> [LocalMirrorRecord] {
        let boundedLimit = min(max(limitPerType, 1), CSVImportLimits.maximumRowsPerTable)
        try Task.checkCancellation()
        let result = try await persistence.mirroredRecords(in: namespace, recordTypes: recordTypes, limitPerType: boundedLimit)
        try Task.checkCancellation()
        return result
    }
}

/// The only mutations these adapters can initiate are delegated to this
/// authority. It is deliberately separate from read projection so a feature
/// cannot manufacture CloudKit acknowledgements or privileged operations.
@MainActor
protocol ProductionFeatureMutationAuthorizing: Sendable {
    func validateDraft(_ draft: WorkOrderDraft, authorization: OperationsAuthorization, in namespace: PersistenceNamespace) async throws -> WorkOrderValidation
    func stageTopology(_ request: TopologyWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
    func stageTemplate(_ request: TemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
    func stageModuleTemplate(_ request: ModuleTemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
    func stageIPAM(_ request: IPAMWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
    func stagedDraft(id: ObjectID, in namespace: PersistenceNamespace) async throws -> WorkOrderDraft
    func reserve(
        _ draft: WorkOrderDraft, authorization: OperationsAuthorization,
        in namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation
    func refreshReservation(
        _ reservation: WorkOrderReservationPresentation, authorization: OperationsAuthorization,
        in namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation
    func requestApproval(for workOrderID: ObjectID, authorization: OperationsAuthorization, in namespace: PersistenceNamespace) async throws
    func beginExecution(
        workOrderID: ObjectID, reservationID: ObjectID, intentDigest: IntentDigest, authorization: OperationsAuthorization,
        in namespace: PersistenceNamespace) async throws
    func complete(workOrderID: ObjectID, evidence: [EvidenceHash], authorization: OperationsAuthorization, in namespace: PersistenceNamespace) async throws
    func requestCancellation(
        workOrderID: ObjectID, reason: String, physicalStatus: CancellationPhysicalStatus,
        authorization: OperationsAuthorization, in namespace: PersistenceNamespace
    ) async throws -> WorkOrderReservationPresentation
    func resolveCancellation(
        workOrderID: ObjectID, reason: String, releaseAuthorization: CancellationReleaseAuthorization,
        authorization: OperationsAuthorization, in namespace: PersistenceNamespace) async throws
    func createCorrectiveWorkOrder(
        for reconciliationID: ObjectID, authorization: OperationsAuthorization,
        in namespace: PersistenceNamespace
    ) async throws -> ObjectID
    func exportImmutableAudit(authorization: AuthorizedOperationContext, in namespace: PersistenceNamespace) async throws -> URL
}

protocol ProductionForegroundSynchronizing: Sendable {
    func synchronizeForeground(in namespace: PersistenceNamespace) async -> SyncReceipt
}

@MainActor
protocol ProductionWorkspaceAccessReading: Sendable {
    func workspaceAccess(in namespace: PersistenceNamespace) async throws -> WorkspaceAccessPresentation
}

enum ProductionAdapterError: LocalizedError {
    case namespaceMismatch
    case invalidExportAuthorization
    case malformedAuthoritativeMirrorRecord(ResourceKey, String)
    case mirrorRecordIdentityMismatch(ResourceKey, String)

    var errorDescription: String? {
        switch self {
        case .namespaceMismatch: "The requested data is outside the active account workspace."
        case .invalidExportAuthorization: "The export authorization is not valid for the active account workspace."
        case let .malformedAuthoritativeMirrorRecord(resourceKey, recordType):
            "The authoritative \(recordType) mirror record \(resourceKey.description) is malformed."
        case let .mirrorRecordIdentityMismatch(resourceKey, recordType):
            "The authoritative \(recordType) mirror record \(resourceKey.description) has a mismatched resource identity."
        }
    }
}

func lexicalLess(_ lhs: [String], _ rhs: [String]) -> Bool {
    for (left, right) in zip(lhs, rhs) where left != right { return left < right }
    return lhs.count < rhs.count
}

/// Session-local history is intentionally keyed by the complete account scope;
/// it never leaks favorites or recently viewed IDs into another account or a
/// renewed workspace session.
actor ScopedInventoryHistoryAdapter: InventoryHistoryStoring {
    private let maximumRecents: Int
    private var recentsByScope: [InventoryAccountScope: [ObjectID]] = [:]
    private var favoritesByScope: [InventoryAccountScope: Set<ObjectID>] = [:]

    init(maximumRecents: Int = 50) {
        self.maximumRecents = min(max(maximumRecents, 1), 50)
    }

    func recent(in scope: InventoryAccountScope) async -> [ObjectID] {
        Array(recentsByScope[scope, default: []].prefix(maximumRecents))
    }

    func favorites(in scope: InventoryAccountScope) async -> Set<ObjectID> {
        favoritesByScope[scope, default: []]
    }

    func recordRecent(_ id: ObjectID, in scope: InventoryAccountScope) async {
        var recents = recentsByScope[scope, default: []]
        recents.removeAll { $0 == id }
        recents.insert(id, at: 0)
        recentsByScope[scope] = Array(recents.prefix(maximumRecents))
    }

    func toggleFavorite(_ id: ObjectID, in scope: InventoryAccountScope) async -> Set<ObjectID> {
        var favorites = favoritesByScope[scope, default: []]
        if favorites.contains(id) { favorites.remove(id) } else { favorites.insert(id) }
        favoritesByScope[scope] = favorites
        return favorites
    }
}

/// Read-only SwiftData/domain projections for browse, trace, scan, template,
/// and IPAM features. Every entry point verifies the complete namespace before
/// asking the lease-enforcing mirror reader for a bounded record set.
actor SwiftDataFeatureReadAdapter: InventoryQuerying, TopologyBrowsing, TraceInspecting, TemplateCatalogQuerying, IPAMBrowsing, ScannedObjectResolving,
    PrivacySafeLabelSourcing, CSVWorkspaceExporting
{
    let account: AccountContext
    let persistence: SwiftDataPersistenceStore
    let reader: any ScopedMirrorRecordEnumerating
    let currentAuthorizationContext: any CurrentAuthorizationContextProviding
    let operationBoundary: ProductionOperationBoundary
    let recordLimitPerType: Int

    init(
        account: AccountContext, persistence: SwiftDataPersistenceStore, reader: any ScopedMirrorRecordEnumerating,
        currentAuthorizationContext: any CurrentAuthorizationContextProviding,
        operationBoundary: ProductionOperationBoundary,
        recordLimitPerType: Int = 100_000
    ) {
        self.account = account
        self.persistence = persistence
        self.reader = reader
        self.currentAuthorizationContext = currentAuthorizationContext
        self.operationBoundary = operationBoundary
        self.recordLimitPerType = min(max(recordLimitPerType, 1), 100_000)
    }
}
