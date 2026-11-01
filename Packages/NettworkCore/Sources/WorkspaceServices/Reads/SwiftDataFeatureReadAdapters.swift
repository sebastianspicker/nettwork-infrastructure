import CloudSync
import ContentSafety
import CryptoKit
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

/// Bounded, account-scoped access to already-verified local-mirror records.
/// The persistence implementation must validate the active namespace lease
/// before returning records and must retain tombstones for callers that need
/// to surface their effect in a read model.
public protocol ScopedMirrorRecordEnumerating: Sendable {
    func records(in namespace: PersistenceNamespace, recordTypes: Set<String>, limitPerType: Int) async throws -> [LocalMirrorRecord]
    /// The newest visible, non-tombstone records, newest first by
    /// `serverModifiedAt`. Never fails on volume; meant for append-only history.
    func newestRecords(in namespace: PersistenceNamespace, recordTypes: Set<String>, limit: Int) async throws -> [LocalMirrorRecord]
}

extension ScopedMirrorRecordEnumerating {
    public func newestRecords(in namespace: PersistenceNamespace, recordTypes: Set<String>, limit: Int) async throws -> [LocalMirrorRecord] {
        let records = try await self.records(in: namespace, recordTypes: recordTypes, limitPerType: 100_000)
        return Array(records.filter { !$0.isTombstone }.sorted { $0.serverModifiedAt > $1.serverModifiedAt }.prefix(limit))
    }

    /// D-6: audit reads cover only the newest events, newest first by
    /// occurrence. Older events stay stored and in the audit export.
    func newestAudits(in namespace: PersistenceNamespace, quarantining: Bool = false) async throws -> [AuditEvent] {
        let records = try await newestRecords(
            in: namespace, recordTypes: [CloudRecordNaming.auditRecordType, LocalRecordKind.auditEvent], limit: AuditReadLimits.newestEvents)
        return try (quarantining ? MirrorRecordQuarantine(screening: records).accepted : records)
            .decoded(AuditEvent.self, recordType: CloudRecordNaming.auditRecordType, expectedResourceKey: { .object($0.id) })
            .sorted { $0.occurredAt > $1.occurredAt }
    }
}

enum AuditReadLimits {
    static let newestEvents = 5_000

    static func recentSummary(for id: ObjectID, in audits: [AuditEvent]) -> [String] {
        audits
            .filter { $0.affectedObjectIDs.contains(id) || $0.affectedResourceKeys.contains(.object(id)) }
            .prefix(10)
            .map { "\($0.occurredAt.formatted()) · \($0.result.rawValue) · \($0.actorID)" }
    }
}

public actor SwiftDataMirrorRecordEnumerator: ScopedMirrorRecordEnumerating {
    let persistence: SwiftDataPersistenceStore

    public init(persistence: SwiftDataPersistenceStore) { self.persistence = persistence }

    public func records(in namespace: PersistenceNamespace, recordTypes: Set<String>, limitPerType: Int) async throws -> [LocalMirrorRecord] {
        let boundedLimit = min(max(limitPerType, 1), CSVImportLimits.maximumRowsPerTable)
        try Task.checkCancellation()
        let result = try await persistence.mirroredRecords(in: namespace, recordTypes: recordTypes, limitPerType: boundedLimit)
        try Task.checkCancellation()
        return result
    }

    public func newestRecords(in namespace: PersistenceNamespace, recordTypes: Set<String>, limit: Int) async throws -> [LocalMirrorRecord] {
        try Task.checkCancellation()
        return try await persistence.newestMirroredRecords(in: namespace, recordTypes: recordTypes, limit: min(max(limit, 1), 100_000))
    }
}

/// The only mutations these adapters can initiate are delegated to this
/// authority. It is deliberately separate from read projection so a feature
/// cannot manufacture CloudKit acknowledgements or privileged operations.
@MainActor
public protocol ProductionFeatureMutationAuthorizing: Sendable {
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
    func stagedDrafts(in namespace: PersistenceNamespace) async throws -> [WorkOrderDraft]
    func reopenWorkOrder(id: ObjectID, authorization: OperationsAuthorization, in namespace: PersistenceNamespace) async throws -> ReopenedWorkOrder
}

public protocol ProductionForegroundSynchronizing: Sendable {
    func synchronizeForeground(in namespace: PersistenceNamespace) async -> SyncReceipt
}

@MainActor
public protocol ProductionWorkspaceAccessReading: Sendable {
    func workspaceAccess(in namespace: PersistenceNamespace) async throws -> WorkspaceAccessPresentation
}

enum ProductionAdapterError: LocalizedError {
    case namespaceMismatch
    case invalidExportAuthorization
    case malformedAuthoritativeMirrorRecord(ResourceKey, String)
    case mirrorRecordIdentityMismatch(ResourceKey, String)
    case mirrorRecordLimitExceeded(Int)
    case quarantinedRecordsBlockProjection(Int)

    var errorDescription: String? {
        switch self {
        case .namespaceMismatch: "The requested data is outside the active account workspace."
        case .invalidExportAuthorization: "The export authorization is not valid for the active account workspace."
        case let .malformedAuthoritativeMirrorRecord(resourceKey, recordType):
            "The authoritative \(recordType) mirror record \(resourceKey.description) is malformed."
        case let .mirrorRecordIdentityMismatch(resourceKey, recordType):
            "The authoritative \(recordType) mirror record \(resourceKey.description) has a mismatched resource identity."
        case let .mirrorRecordLimitExceeded(limit):
            "The local mirror holds more than the supported record limit of \(limit) for one record type, so it cannot be shown completely."
        case let .quarantinedRecordsBlockProjection(count):
            "\(count) mirror record(s) could not be read, and other records depend on them, so this view cannot be shown reliably."
        }
    }
}

func lexicalLess(_ lhs: [String], _ rhs: [String]) -> Bool {
    for (left, right) in zip(lhs, rhs) where left != right { return left < right }
    return lhs.count < rhs.count
}

/// Read-only SwiftData/domain projections for browse, trace, scan, template,
/// and IPAM features. Every entry point verifies the complete namespace before
/// asking the lease-enforcing mirror reader for a bounded record set.
public actor SwiftDataFeatureReadAdapter: InventoryQuerying, TopologyBrowsing, TraceInspecting, TemplateCatalogQuerying, IPAMBrowsing, ScannedObjectResolving,
    PrivacySafeLabelSourcing, CSVWorkspaceExporting
{
    let account: AccountContext
    let persistence: SwiftDataPersistenceStore
    let reader: any ScopedMirrorRecordEnumerating
    let currentAuthorizationContext: any CurrentAuthorizationContextProviding
    let operationBoundary: ProductionOperationBoundary
    let recordLimitPerType: Int
    var projectionCache: CachedMirrorProjection?

    public init(
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
