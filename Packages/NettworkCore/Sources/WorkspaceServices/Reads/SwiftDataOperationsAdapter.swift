import CloudSync
import ContentSafety
import CryptoKit
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Persistence
import Synchronization
import WorkspaceChangeControl

public final class SwiftDataOperationsAdapter: OperationsFeatureService, OperationsReadModel, ReconciliationFeatureService {
    private let account: AccountContext
    private let persistence: SwiftDataPersistenceStore
    private let reader: any ScopedMirrorRecordEnumerating
    private let mutations: any ProductionFeatureMutationAuthorizing
    private let synchronizer: any ProductionForegroundSynchronizing
    private let workspaceAccessReader: any ProductionWorkspaceAccessReading
    private let telemetryExternalSignalProvider: any PrivacySafeSyncTelemetryExternalSignalProviding
    private let operationBoundary: ProductionOperationBoundary
    private let recordLimitPerType: Int
    /// Concurrent `reports()`/`auditEvents` calls may overlap, so the cache sits behind a lock.
    private let projectionCache = Mutex<CachedMirrorProjection?>(nil)

    public init(
        account: AccountContext, persistence: SwiftDataPersistenceStore, reader: any ScopedMirrorRecordEnumerating,
        mutations: any ProductionFeatureMutationAuthorizing, synchronizer: any ProductionForegroundSynchronizing,
        workspaceAccessReader: any ProductionWorkspaceAccessReading, telemetryExternalSignalProvider: any PrivacySafeSyncTelemetryExternalSignalProviding,
        operationBoundary: ProductionOperationBoundary, recordLimitPerType: Int = 100_000
    ) {
        self.account = account
        self.persistence = persistence
        self.reader = reader
        self.mutations = mutations
        self.synchronizer = synchronizer
        self.workspaceAccessReader = workspaceAccessReader
        self.telemetryExternalSignalProvider = telemetryExternalSignalProvider
        self.operationBoundary = operationBoundary
        self.recordLimitPerType = min(max(recordLimitPerType, 1), 100_000)
    }

    public func synchronizeForeground() async -> SyncReceipt { await synchronizer.synchronizeForeground(in: account.namespace) }

    public func validateDraft(_ draft: WorkOrderDraft, authorization: OperationsAuthorization) async throws -> WorkOrderValidation {
        try await mutations.validateDraft(draft, authorization: authorization, in: account.namespace)
    }

    public func stagedDraft(id: ObjectID) async throws -> WorkOrderDraft {
        try await mutations.stagedDraft(id: id, in: account.namespace)
    }

    public func reserve(
        _ draft: WorkOrderDraft,
        authorization: OperationsAuthorization
    ) async throws -> WorkOrderReservationPresentation {
        try await mutations.reserve(
            draft,
            authorization: authorization, in: account.namespace)
    }
    public func refreshReservation(
        _ reservation: WorkOrderReservationPresentation,
        authorization: OperationsAuthorization
    ) async throws -> WorkOrderReservationPresentation {
        try await mutations.refreshReservation(
            reservation,
            authorization: authorization, in: account.namespace)
    }
    public func requestApproval(
        for workOrderID: ObjectID,
        authorization: OperationsAuthorization
    ) async throws {
        try await mutations.requestApproval(
            for: workOrderID, authorization: authorization,
            in: account.namespace)
    }
    public func beginExecution(
        workOrderID: ObjectID, reservationID: ObjectID, intentDigest: IntentDigest,
        authorization: OperationsAuthorization
    ) async throws {
        try await mutations.beginExecution(
            workOrderID: workOrderID, reservationID: reservationID,
            intentDigest: intentDigest, authorization: authorization, in: account.namespace)
    }
    public func complete(
        workOrderID: ObjectID, evidence: [EvidenceHash],
        authorization: OperationsAuthorization
    ) async throws {
        try await mutations.complete(
            workOrderID: workOrderID, evidence: evidence,
            authorization: authorization, in: account.namespace)
    }
    public func requestCancellation(
        workOrderID: ObjectID, reason: String, physicalStatus: CancellationPhysicalStatus,
        authorization: OperationsAuthorization
    ) async throws -> WorkOrderReservationPresentation {
        try await mutations.requestCancellation(
            workOrderID: workOrderID, reason: reason, physicalStatus: physicalStatus, authorization: authorization, in: account.namespace)
    }
    public func resolveCancellation(
        workOrderID: ObjectID, reason: String, releaseAuthorization: CancellationReleaseAuthorization,
        authorization: OperationsAuthorization
    ) async throws {
        try await mutations.resolveCancellation(
            workOrderID: workOrderID, reason: reason,
            releaseAuthorization: releaseAuthorization, authorization: authorization, in: account.namespace)
    }

    public func workOrders() async throws -> [WorkOrderSummary] {
        let records = try await reader.records(
            in: account.namespace, recordTypes: [CloudRecordNaming.workOrderRecordType, LocalRecordKind.workOrder], limitPerType: recordLimitPerType)
        let updatedAt = Dictionary(records.map { ($0.resourceKey, $0.serverModifiedAt) }, uniquingKeysWith: max)
        return try records.decoded(WorkOrder.self, recordType: CloudRecordNaming.workOrderRecordType, expectedResourceKey: { .object($0.id) })
            .map { order in
                WorkOrderSummary(
                    id: order.id, title: order.title, status: order.status, ticket: order.ticket,
                    reservationExpiresAt: order.reservation?.acknowledgedByCloudKit?.expiresAt, updatedAt: updatedAt[.object(order.id)] ?? .distantPast)
            }
            .sorted { ($0.updatedAt, $0.id.description) > ($1.updatedAt, $1.id.description) }
    }

    public func stagedDrafts() async throws -> [WorkOrderDraft] {
        try await mutations.stagedDrafts(in: account.namespace)
    }

    public func reopenWorkOrder(id: ObjectID, authorization: OperationsAuthorization) async throws -> ReopenedWorkOrder {
        try await mutations.reopenWorkOrder(id: id, authorization: authorization, in: account.namespace)
    }

    public func auditEvents(matching query: String) async throws -> [AuditEventPresentation] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        return try await reader.newestAudits(in: account.namespace)
            .filter { event in needle.isEmpty || Self.auditSummary(event).localizedLowercase.contains(needle) }
            .prefix(200)
            .map { AuditEventPresentation(event: $0, summary: Self.auditSummary($0)) }
    }

    public func reports() async throws -> [OperationsReport] {
        try await operationBoundary.perform(.reportGeneration, outputRecordCount: { $0.count }) {
            try await self.generateReports()
        }
    }

    private func generateReports() async throws -> [OperationsReport] {
        let projection = try await featureProjection()
        let audits = try await reader.newestAudits(in: account.namespace)
        let externalSignals = await telemetryExternalSignalProvider.currentSignals()
        let now = Date.now
        let portStates = Dictionary(grouping: projection.topology.ports) { projection.portState(for: $0.id) }.mapValues(\.count)
        let activeWorkOrders = projection.workOrders.filter {
            [.reserved, .approved, .executing, .cancellationRequested].contains($0.status)
        }
        let staleReservations = activeWorkOrders.filter {
            guard let acknowledgement = $0.reservation?.acknowledgedByCloudKit else { return true }
            return acknowledgement.expiresAt <= now
        }
        let statusCounts = Dictionary(grouping: projection.workOrders, by: \.status).mapValues(\.count)
        let activeAddressesByVRF = Dictionary(grouping: projection.addresses.filter(\.isActive), by: \.vrfID)
        let prefixUtilization = projection.prefixes.filter(\.isActive).map { prefix in
            prefix.utilization(addresses: activeAddressesByVRF[prefix.vrfID, default: []])
        }
        let averagePrefixUse = prefixUtilization.isEmpty ? 0 : prefixUtilization.map(\.consumedFraction).reduce(0, +) / Double(prefixUtilization.count)
        let activeVLANs = projection.vlans.filter(\.isActive)
        let activeAssignments = projection.assignments.filter(\.isActive)
        let activeMemberships = projection.memberships.filter(\.isActive)
        let conflictSummary = "\(projection.conflictCount)"
        let lastContact =
            projection.syncState?.lastSuccessfulServerContact.map {
                "\(max(0, Int(now.timeIntervalSince($0)))) seconds ago"
            } ?? "not confirmed"
        var reports = [
            OperationsReport(
                id: "ports", title: "Port availability", generatedAt: now,
                summary:
                    "\(portStates[.free, default: 0]) free, \(portStates[.reserved, default: 0]) reserved, \(portStates[.occupied, default: 0]) occupied, \(portStates[.planned, default: 0]) planned, \(portStates[.unavailable, default: 0]) unavailable.",
                isFinal: false),
            OperationsReport(
                id: "inventory", title: "Inventory", generatedAt: now,
                summary:
                    "\(projection.hierarchy.locations.filter { $0.deletedAt == nil }.count) locations, \(projection.hierarchy.racks.filter { $0.deletedAt == nil }.count) racks, \(projection.topology.devices.count) devices, \(projection.topology.modules.count) modules, \(projection.topology.ports.count) ports.",
                isFinal: false),
            OperationsReport(
                id: "connectivity", title: "Trace coverage", generatedAt: now,
                summary:
                    "\(projection.topology.cables.count) cables and \(projection.topology.internalLinks.count) internal links across \(projection.topology.ports.count) ports.",
                isFinal: false),
            OperationsReport(
                id: "reservations", title: "Reservation health", generatedAt: now,
                summary: "\(activeWorkOrders.count) active work orders; \(staleReservations.count) missing or expired Cloud confirmation.", isFinal: false),
            OperationsReport(
                id: "work-orders", title: "Work orders", generatedAt: now,
                summary: WorkOrderStatus.allCases.map { "\($0.rawValue): \(statusCounts[$0, default: 0])" }.joined(separator: ", "), isFinal: false),
            OperationsReport(
                id: "conflicts", title: "Reconciliation", generatedAt: now,
                summary: "\(conflictSummary) unresolved comparison(s).", isFinal: false),
        ]
        reports.append(
            contentsOf: Self.operationalHealthReports(
                projection: projection, externalSignals: externalSignals, averagePrefixUse: averagePrefixUse,
                activeVLANs: activeVLANs, activeAssignments: activeAssignments, activeMemberships: activeMemberships,
                audits: audits, lastContact: lastContact, generatedAt: now))
        return reports
    }

    private static func operationalHealthReports(
        projection: MirrorProjection,
        externalSignals: PrivacySafeSyncTelemetryExternalSignals,
        averagePrefixUse: Double,
        activeVLANs: [VLAN],
        activeAssignments: [IPAddressAssignment],
        activeMemberships: [InterfaceVLANMembership],
        audits: [AuditEvent],
        lastContact: String,
        generatedAt: Date
    ) -> [OperationsReport] {
        [
            OperationsReport(
                id: "ipam", title: "IPAM utilization", generatedAt: generatedAt,
                summary:
                    "\(projection.prefixes.filter(\.isActive).count) active prefixes, \(projection.addresses.filter(\.isActive).count) addresses, average consumed capacity \(Int(averagePrefixUse * 100))%.",
                isFinal: false),
            OperationsReport(
                id: "vlans", title: "VLAN and assignment coverage", generatedAt: generatedAt,
                summary: "\(activeVLANs.count) VLANs, \(activeAssignments.count) address assignments, \(activeMemberships.count) interface memberships.",
                isFinal: false),
            OperationsReport(
                id: "sync", title: "Sync, quota, and backup", generatedAt: generatedAt,
                summary:
                    "Last verified server contact: \(lastContact). \(externalQuotaDescription(externalSignals.quota)) \(externalBackupDescription(externalSignals.backupAge))",
                isFinal: false),
            OperationsReport(
                id: "audit", title: "Immutable audit", generatedAt: generatedAt,
                summary: "Latest \(audits.count) immutable event(s), \(audits.filter { $0.result == .accepted }.count) accepted.", isFinal: false),
        ]
    }

    public func syncHealth() async throws -> SyncHealthPresentation {
        let externalSignals = await telemetryExternalSignalProvider.currentSignals()
        let status = try await persistence.status(in: account.namespace)
        let quarantineCount = try await persistence.quarantineCount(in: account.namespace)
        let conflictCount = try await persistence.unresolvedConflictCount(in: account.namespace)
        let sync = try await persistence.syncState(in: account.namespace)
        let mirror = CloudMirrorStatus(
            queueDepth: status.queueDepth, oldestQueuedAt: status.oldestQueuedAt, quarantineCount: quarantineCount,
            conflictCount: conflictCount, lastSuccessfulServerContact: sync?.lastSuccessfulServerContact)
        return SyncHealthPresentation(
            mirror: SyncMirrorPresentation(
                conflictCount: mirror.conflictCount,
                lastSuccessfulServerContact: mirror.lastSuccessfulServerContact
            ),
            queueDescription: "\(status.queueDepth) queued operation(s). \(Self.externalQuotaDescription(externalSignals.quota))",
            quarantineDescription: "\(quarantineCount) quarantined record(s).",
            backupDescription: Self.externalBackupDescription(externalSignals.backupAge), accountFresh: sync?.lastSuccessfulServerContact != nil)
    }

    public func workspaceAccess() async throws -> WorkspaceAccessPresentation {
        try await workspaceAccessReader.workspaceAccess(in: account.namespace)
    }

    public func exportImmutableAudit(authorization: AuthorizedOperationContext) async throws -> URL {
        guard authorization.validateCurrent(account: account) else { throw ProductionAdapterError.invalidExportAuthorization }
        return try await mutations.exportImmutableAudit(authorization: authorization, in: account.namespace)
    }

    private static func externalQuotaDescription(_ quota: PrivacySafeSyncTelemetryExternalQuota) -> String {
        switch quota {
        case .unavailable:
            return "External quota is unavailable."
        case let .reported(usedBytes, limitBytes):
            return "External quota reports \(usedBytes) of \(limitBytes) bytes used."
        }
    }

    private static func externalBackupDescription(_ backupAge: PrivacySafeSyncTelemetryExternalBackupAge) -> String {
        switch backupAge {
        case .unavailable:
            return "Backup age is unavailable; the local mirror is not a backup authority."
        case let .reported(ageSeconds):
            return "The organization backup authority reports an age of \(ageSeconds) seconds."
        }
    }

    public func unresolvedComparisons() async throws -> [ReconciliationComparison] {
        try await persistence.unresolvedCases(in: account.namespace, limit: 200)
            .sorted { $0.detectedAt < $1.detectedAt }
            .prefix(200)
            .map { item in
                ReconciliationComparison(
                    id: item.id, title: "\(item.reason.rawValue) · \(item.operationID.description)",
                    reason: item.reason.rawValue, baseSummary: Self.snapshotSummary(item.base), intendedSummary: Self.snapshotSummary(item.intended),
                    currentSummary: Self.snapshotSummary(item.current), isSecurityEvent: item.isSecurityEvent)
            }
    }

    public func createCorrectiveWorkOrder(for reconciliationID: ObjectID, authorization: OperationsAuthorization) async throws -> ObjectID {
        try await mutations.createCorrectiveWorkOrder(for: reconciliationID, authorization: authorization, in: account.namespace)
    }

    public func correctiveWorkOrder(
        for reconciliationID: ObjectID,
        authorization: OperationsAuthorization
    ) async throws -> ObjectID {
        try await createCorrectiveWorkOrder(for: reconciliationID, authorization: authorization)
    }

    private func featureProjection() async throws -> MirrorProjection {
        let inputs = try await MirrorProjectionInputs(persistence: persistence, namespace: account.namespace)
        if let cached = projectionCache.withLock({ $0 }).reusable(for: inputs) { return cached }
        let records = try await reader.records(in: account.namespace, recordTypes: MirrorProjection.featureRecordTypes, limitPerType: recordLimitPerType)
        let projection = try MirrorProjection(
            records: records, conflicts: inputs.conflicts, conflictResourceKeys: inputs.conflictResourceKeys, conflictCount: inputs.conflictCount,
            syncState: inputs.syncState
        )
        projectionCache.withLock { $0 = CachedMirrorProjection(inputs: inputs, projection: projection) }
        return projection
    }
    private static func auditSummary(_ event: AuditEvent) -> String {
        "\(event.result.rawValue) · \(event.actorID) · \(event.ticket ?? event.workOrderID?.description ?? event.operationID.description)"
    }
    private static func snapshotSummary(_ values: [ResourceKey: ReconciliationSnapshot]) -> String {
        values.isEmpty ? "None" : "\(values.count) record snapshot(s)"
    }
}
