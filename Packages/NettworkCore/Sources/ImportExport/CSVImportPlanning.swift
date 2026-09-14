import ContentSafety
import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum ImportAuthorizationError: Error, Equatable, Sendable {
    case actionMismatch, administratorRequired, writePermissionRequired, staleContext, namespaceMismatch
}
public enum ImportPlanError: Error, Equatable, Sendable {
    case workspaceNotEmpty, invalidCounts, invalidSchemaRecord, dryRunFailed, inputDigestMismatch, activationConflict, activationReceiptMismatch,
        invalidStagingHandle
}

public struct ImportDryRunReport: Codable, Hashable, Sendable {
    public let canonicalSHA256: String
    public let validatorVersion: Int
    public let validatedRecordCount: Int

    public init(canonicalSHA256: String, validatorVersion: Int, validatedRecordCount: Int) {
        self.canonicalSHA256 = canonicalSHA256
        self.validatorVersion = validatorVersion
        self.validatedRecordCount = validatedRecordCount
    }
}

/// This is immutable so a reviewed dry-run cannot be substituted before activation.
public struct ImportPlan: Codable, Hashable, Sendable {
    public let namespace: PersistenceNamespace
    public let canonicalSHA256: String
    public let recordCounts: [String: Int]
    public let totalRecordCount: Int
    public let expectedEmptyWorkspace: Bool
    public let stagingGeneration: UInt64
    public let operationID: ObjectID
    /// Stable across a retry or process restart. By default a CSV import uses
    /// its operation identity as its transfer identity for compatibility.
    public let transferID: ObjectID
    public let dryRunReport: ImportDryRunReport

    public init(
        namespace: PersistenceNamespace, canonicalSHA256: String, recordCounts: [String: Int], totalRecordCount: Int, expectedEmptyWorkspace: Bool = true,
        stagingGeneration: UInt64, operationID: ObjectID,
        transferID: ObjectID? = nil, dryRunReport: ImportDryRunReport
    ) throws {
        guard totalRecordCount == recordCounts.values.reduce(0, +), totalRecordCount <= CSVImportLimits.maximumRowsTotal,
            recordCounts.values.allSatisfy({ $0 >= 0 && $0 <= CSVImportLimits.maximumRowsPerTable })
        else { throw ImportPlanError.invalidCounts }
        guard dryRunReport.canonicalSHA256 == canonicalSHA256,
            dryRunReport.validatorVersion >= 1,
            dryRunReport.validatedRecordCount == totalRecordCount
        else { throw ImportPlanError.dryRunFailed }
        self.namespace = namespace
        self.canonicalSHA256 = canonicalSHA256
        self.recordCounts = recordCounts
        self.totalRecordCount = totalRecordCount
        self.expectedEmptyWorkspace = expectedEmptyWorkspace
        self.stagingGeneration = stagingGeneration
        self.operationID = operationID
        self.transferID = transferID ?? operationID
        self.dryRunReport = dryRunReport
    }
}

public struct ImportStagingHandle: Codable, Hashable, Sendable {
    public let id: ObjectID
    /// The opaque durable directory identity. Production file-backed stores
    /// use the transfer ID here so the same authorized operation can discover
    /// and verify its sidecar after a retry or process restart.
    public let transferID: ObjectID
    public let namespace: PersistenceNamespace
    public let generation: UInt64
    public init(id: ObjectID = .init(), transferID: ObjectID? = nil, namespace: PersistenceNamespace, generation: UInt64) {
        self.id = id
        self.transferID = transferID ?? id
        self.namespace = namespace
        self.generation = generation
    }
}

/// Callers must make cleanup intent explicit. Retryable transport, authority,
/// and authorization failures retain their canonical staging sidecar.
public enum StagedTransferCleanupDisposition: String, Codable, Hashable, Sendable {
    case retainRetryable
    case discardConfirmedActivation
    case discardConfirmedCancellation
    case discardUnrecoverableInput

    public var discardsStaging: Bool { self != .retainRetryable }
}

public enum StagedTransferCleanupClassifier {
    public static func disposition(for error: Error) -> StagedTransferCleanupDisposition {
        switch error {
        case _ as ArchiveValidationError:
            return .discardUnrecoverableInput
        case FileBackedStagingError.stagedPayloadMismatch,
            WorkspaceTransferRecordError.malformedJSONL,
            WorkspaceTransferRecordError.nonCanonicalJSONL,
            WorkspaceTransferRecordError.rowTooLarge,
            WorkspaceTransferRecordError.transferTooLarge,
            WorkspaceTransferRecordError.tooManyRows:
            return .discardUnrecoverableInput
        default:
            return .retainRetryable
        }
    }
}

/// The persistence adapter keeps staging unreachable from normal reads. Activate
/// is its only visibility transition and must compare-and-swap the empty state.
public protocol ImportStagingStore: Sendable {
    func currentAccount() async throws -> AccountContext
    func workspaceIsEmpty(in namespace: PersistenceNamespace) async throws -> Bool
    /// Must validate parents, cycles, placement, endpoint/media/occupancy,
    /// template, IPAM, VLAN, assignment, and anchor invariants as one candidate graph.
    func dryRun(_ records: [ImportRecord], in namespace: PersistenceNamespace) async throws -> ImportDryRunReport
    func createStaging(for plan: ImportPlan) async throws -> ImportStagingHandle
    func stage(_ records: [ImportRecord], in staging: ImportStagingHandle) async throws
    /// On success, returns exactly `expectedReceipt` from the atomic visibility transition.
    func activate(
        _ staging: ImportStagingHandle, plan: ImportPlan, requiringEmptyWorkspace: Bool,
        expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt
    /// Explicit terminal cleanup only: confirmed cancellation or unrecoverable
    /// input. Retryable failures retain the sidecar for a later reopen.
    func discard(_ staging: ImportStagingHandle) async
}

public enum CanonicalImportDigest {
    public static func digest(records: [ImportRecord]) -> String {
        var hasher = SHA256()
        for record in records.sorted(by: canonicalLess) {
            update(record.table, into: &hasher)
            for key in record.values.keys.sorted() {
                update(key, into: &hasher)
                update(record.values[key] ?? "", into: &hasher)
            }
            hasher.update(data: Data([0x1E]))
        }
        return HexDigest.string(hasher.finalize())
    }

    private static func canonicalLess(_ lhs: ImportRecord, _ rhs: ImportRecord) -> Bool {
        lhs.table == rhs.table ? stableRecordText(lhs) < stableRecordText(rhs) : lhs.table < rhs.table
    }
    private static func stableRecordText(_ record: ImportRecord) -> String {
        record.values.keys.sorted().map { "\($0)\u{1F}\(record.values[$0] ?? "")" }.joined(separator: "\u{1E}")
    }
    private static func update(_ string: String, into hasher: inout SHA256) {
        let bytes = Data(string.utf8)
        var length = UInt64(bytes.count).bigEndian
        withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
        hasher.update(data: bytes)
    }
}

/// Deterministically binds a CSV activation receipt to the reviewed plan rather
/// than merely to its operation identifier and workspace zone.
public enum CSVImportActivationReceipt {
    public static func expected(for plan: ImportPlan) throws -> OperationReceipt {
        let intent = try CanonicalActivationReceipt.intent(
            domain: "nettwork.csv-import-activation-intent.v1", namespace: plan.namespace,
            operationID: plan.operationID,
            fields: [
                plan.canonicalSHA256, String(plan.totalRecordCount),
                plan.expectedEmptyWorkspace ? "true" : "false", String(plan.stagingGeneration),
                plan.transferID.description, String(plan.dryRunReport.validatorVersion),
                String(plan.dryRunReport.validatedRecordCount),
            ] + plan.recordCounts.keys.sorted().flatMap { key in [key, String(plan.recordCounts[key] ?? 0)] }
        )
        return OperationReceipt(
            workspaceZone: plan.namespace.workspaceZone, operationID: plan.operationID,
            intentDigest: intent, auditEventID: AuditEvent.deterministicID(for: plan.operationID))
    }
}

public struct AuthorizedCSVImportService: Sendable {
    private let store: any ImportStagingStore
    private let currentContext: any CurrentAuthorizationContextProviding

    public init(store: any ImportStagingStore, currentContext: any CurrentAuthorizationContextProviding) {
        self.store = store
        self.currentContext = currentContext
    }

    public func makePlan(records: [ImportRecord], context: AuthorizedOperationContext, stagingGeneration: UInt64) async throws -> ImportPlan {
        try await authorize(context, action: .importCSV)
        try validateSchemaOwned(records)
        let counts = Dictionary(grouping: records, by: \.table).mapValues(\.count)
        guard records.count <= CSVImportLimits.maximumRowsTotal, counts.values.allSatisfy({ $0 <= CSVImportLimits.maximumRowsPerTable }) else {
            throw ImportPlanError.invalidCounts
        }
        guard try await store.workspaceIsEmpty(in: context.account.namespace) else { throw ImportPlanError.workspaceNotEmpty }
        try await authorize(context, action: .importCSV)
        let digest = CanonicalImportDigest.digest(records: records)
        let report = try await store.dryRun(records, in: context.account.namespace)
        try await authorize(context, action: .importCSV)
        guard report.canonicalSHA256 == digest, report.validatedRecordCount == records.count else { throw ImportPlanError.dryRunFailed }
        return try ImportPlan(
            namespace: context.account.namespace, canonicalSHA256: digest, recordCounts: counts, totalRecordCount: records.count,
            stagingGeneration: stagingGeneration, operationID: context.operationID,
            dryRunReport: report)
    }

    public func execute(plan: ImportPlan, records: [ImportRecord], context: AuthorizedOperationContext) async throws -> OperationReceipt {
        try await authorize(context, action: .importCSV)
        try await validateExecutionInputs(plan: plan, records: records, context: context)
        try await authorize(context, action: .importCSV)
        try await validateDryRun(records, for: plan)
        try await authorize(context, action: .importCSV)
        let staging = try await store.createStaging(for: plan)
        guard staging.namespace == plan.namespace, staging.generation == plan.stagingGeneration else { throw ImportPlanError.invalidStagingHandle }
        do {
            return try await activate(records, using: staging, plan: plan, context: context)
        } catch {
            await discardIfTerminal(staging, error: error)
            throw error
        }
    }

    private func validateExecutionInputs(plan: ImportPlan, records: [ImportRecord], context: AuthorizedOperationContext) async throws {
        guard plan.namespace == context.account.namespace, plan.operationID == context.operationID else { throw ImportAuthorizationError.namespaceMismatch }
        try validateSchemaOwned(records)
        guard CanonicalImportDigest.digest(records: records) == plan.canonicalSHA256 else { throw ImportPlanError.inputDigestMismatch }
        let counts = Dictionary(grouping: records, by: \.table).mapValues(\.count)
        guard counts == plan.recordCounts, records.count == plan.totalRecordCount, plan.expectedEmptyWorkspace,
            try await store.workspaceIsEmpty(in: plan.namespace)
        else { throw ImportPlanError.workspaceNotEmpty }
    }

    private func validateDryRun(_ records: [ImportRecord], for plan: ImportPlan) async throws {
        guard try await store.dryRun(records, in: plan.namespace) == plan.dryRunReport else { throw ImportPlanError.dryRunFailed }
    }

    private func activate(_ records: [ImportRecord], using staging: ImportStagingHandle, plan: ImportPlan, context: AuthorizedOperationContext) async throws
        -> OperationReceipt
    {
        try await authorize(context, action: .importCSV)
        try await store.stage(records, in: staging)
        try await authorize(context, action: .importCSV)
        let expectedReceipt = try CSVImportActivationReceipt.expected(for: plan)
        let receipt = try await store.activate(staging, plan: plan, requiringEmptyWorkspace: true, expectedReceipt: expectedReceipt)
        guard receipt == expectedReceipt else { throw ImportPlanError.activationReceiptMismatch }
        return receipt
    }

    private func discardIfTerminal(_ staging: ImportStagingHandle, error: Error) async {
        guard StagedTransferCleanupClassifier.disposition(for: error).discardsStaging else {
            return
        }
        await store.discard(staging)
    }

    private func validateSchemaOwned(_ records: [ImportRecord]) throws {
        for record in records {
            guard let table = CSVTable(rawValue: record.table), let template = CSVSchemaV2.templates[table],
                template.validates(columnNames: Set(record.values.keys))
            else { throw ImportPlanError.invalidSchemaRecord }
        }
    }

    private func authorize(_ context: AuthorizedOperationContext, action: AuthorizedOperationAction) async throws {
        try await ImportOperationAuthorization.validate(
            context, expectedAction: action, currentContext: currentContext,
            currentAccount: { try await self.store.currentAccount() })
    }
}
