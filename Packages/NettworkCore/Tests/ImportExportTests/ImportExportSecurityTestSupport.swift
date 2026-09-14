import ContentSafety
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import ImportExport

final class ImportExportSecurityTests: XCTestCase {}

func fixtureAccount() -> AccountContext {
    let namespace = PersistenceNamespace(
        containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "admin", workspaceID: ObjectID(), zoneName: "zone",
        zoneOwnerRecordName: "admin", sessionGeneration: 1)
    return AccountContext(namespace: namespace, databaseScope: .ownerPrivate, sharePermission: .owner, verifiedAt: .distantPast)
}

func fixtureContext(account: AccountContext, action: AuthorizedOperationAction) -> AuthorizedOperationContext {
    AuthorizedOperationContext(
        operationID: ObjectID(), account: account,
        actor: ActorContext(cloudKitUserRecordName: "admin", role: .administrator, installationID: "test", sessionGeneration: 1), action: action)
}

func deviceRecord(name: String) -> ImportRecord {
    let columns = CSVSchemaV1.templates[.devices]!.columns
    var values = Dictionary(uniqueKeysWithValues: columns.map { ($0, "") })
    values["name"] = name
    return ImportRecord(table: CSVTable.devices.rawValue, values: values)
}

final class RecordingImportStore: ImportStagingStore, @unchecked Sendable {
    let account: AccountContext
    let activationResult: Bool
    let receiptMismatch: ReceiptMismatchKind?
    var stagedCount = 0
    var activationCount = 0
    var discardCount = 0
    private(set) var returnedReceipt: OperationReceipt?
    init(account: AccountContext, activationResult: Bool = true, receiptMismatch: ReceiptMismatchKind? = nil) {
        self.account = account
        self.activationResult = activationResult
        self.receiptMismatch = receiptMismatch
    }
    func currentAccount() async throws -> AccountContext { account }
    func workspaceIsEmpty(in _: PersistenceNamespace) async throws -> Bool { true }
    func dryRun(_ records: [ImportRecord], in _: PersistenceNamespace) async throws -> ImportDryRunReport {
        ImportDryRunReport(canonicalSHA256: CanonicalImportDigest.digest(records: records), validatorVersion: 1, validatedRecordCount: records.count)
    }
    func createStaging(for plan: ImportPlan) async throws -> ImportStagingHandle {
        ImportStagingHandle(namespace: plan.namespace, generation: plan.stagingGeneration)
    }
    func stage(_ records: [ImportRecord], in _: ImportStagingHandle) async throws { stagedCount += records.count }
    func activate(_: ImportStagingHandle, plan _: ImportPlan, requiringEmptyWorkspace _: Bool, expectedReceipt: OperationReceipt) async throws
        -> OperationReceipt
    {
        activationCount += 1
        guard activationResult else { throw ImportPlanError.activationConflict }
        let receipt = try mismatchedReceipt(from: expectedReceipt, kind: receiptMismatch)
        returnedReceipt = receipt
        return receipt
    }
    func discard(_: ImportStagingHandle) async { discardCount += 1 }
}

final class RecordingCSVActivationAuthority: CSVImportActivationAuthority, @unchecked Sendable {
    let account: AccountContext
    let receiptMismatch: ReceiptMismatchKind?
    private(set) var activationCount = 0
    private(set) var returnedReceipt: OperationReceipt?

    init(account: AccountContext, receiptMismatch: ReceiptMismatchKind? = nil) {
        self.account = account
        self.receiptMismatch = receiptMismatch
    }

    func currentAccount() async throws -> AccountContext { account }
    func workspaceIsEmpty(in _: PersistenceNamespace) async throws -> Bool { true }
    func dryRun(_ records: [ImportRecord], in _: PersistenceNamespace) async throws -> ImportDryRunReport {
        ImportDryRunReport(canonicalSHA256: CanonicalImportDigest.digest(records: records), validatorVersion: 1, validatedRecordCount: records.count)
    }
    func activateStagedCSV(records _: [ImportRecord], plan _: ImportPlan, requiringEmptyWorkspace _: Bool, expectedReceipt: OperationReceipt) async throws
        -> OperationReceipt
    {
        activationCount += 1
        let receipt = try mismatchedReceipt(from: expectedReceipt, kind: receiptMismatch)
        returnedReceipt = receipt
        return receipt
    }
}

final class RecordingArchiveRestoreStore: ArchiveRestoreStore, @unchecked Sendable {
    let account: AccountContext
    let receiptMismatch: ReceiptMismatchKind?
    private(set) var activationCount = 0
    private(set) var discardCount = 0
    private(set) var stagingCount = 0
    private(set) var returnedReceipt: OperationReceipt?

    init(account: AccountContext, receiptMismatch: ReceiptMismatchKind?) {
        self.account = account
        self.receiptMismatch = receiptMismatch
    }

    func currentAccount() async throws -> AccountContext { account }
    func isFreshAuthenticatedTarget(in _: PersistenceNamespace) async throws -> Bool { true }
    func dryRun(_: VerifiedArchive, for _: PersistenceNamespace) async throws {}
    func createRestoreStaging(source _: ArchiveSourceProvenance, target: PersistenceNamespace, operationID _: ObjectID) async throws -> ImportStagingHandle {
        stagingCount += 1
        return ImportStagingHandle(namespace: target, generation: 1)
    }
    func stage(_: VerifiedArchive, in _: ImportStagingHandle) async throws {}
    func activateRestore(_: ImportStagingHandle, expectedFreshTarget _: PersistenceNamespace, operationID _: ObjectID, expectedReceipt: OperationReceipt)
        async throws -> OperationReceipt
    {
        activationCount += 1
        let receipt = try mismatchedReceipt(from: expectedReceipt, kind: receiptMismatch)
        returnedReceipt = receipt
        return receipt
    }
    func discardRestore(_: ImportStagingHandle) async { discardCount += 1 }
}

final class RecordingArchiveRestoreActivationAuthority: ArchiveRestoreActivationAuthority, @unchecked Sendable {
    let account: AccountContext
    let receiptMismatch: ReceiptMismatchKind?
    private(set) var returnedReceipt: OperationReceipt?

    init(account: AccountContext, receiptMismatch: ReceiptMismatchKind?) {
        self.account = account
        self.receiptMismatch = receiptMismatch
    }

    func currentAccount() async throws -> AccountContext { account }
    func isFreshAuthenticatedTarget(in _: PersistenceNamespace) async throws -> Bool { true }
    func dryRun(_: VerifiedArchive, for _: PersistenceNamespace) async throws {}
    func activateStagedArchive(
        archive _: VerifiedArchive,
        source _: ArchiveSourceProvenance,
        target _: PersistenceNamespace,
        expectedRootSHA256 _: String,
        operationID _: ObjectID,
        expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        let receipt = try mismatchedReceipt(from: expectedReceipt, kind: receiptMismatch)
        returnedReceipt = receipt
        return receipt
    }
}

enum ReceiptMismatchKind: CaseIterable {
    case intent
    case auditEvent
}

func mismatchedReceipt(from expected: OperationReceipt, kind: ReceiptMismatchKind?) throws -> OperationReceipt {
    guard let kind else { return expected }
    switch kind {
    case .intent:
        return OperationReceipt(
            workspaceZone: expected.workspaceZone,
            operationID: expected.operationID,
            intentDigest: try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 0xA5, count: 32)),
            auditEventID: expected.auditEventID
        )
    case .auditEvent:
        return OperationReceipt(
            workspaceZone: expected.workspaceZone,
            operationID: expected.operationID,
            intentDigest: expected.intentDigest,
            auditEventID: ObjectID()
        )
    }
}

func assertScopeMatchingReceiptMismatch(
    _ receipt: OperationReceipt?,
    expected: OperationReceipt,
    kind: ReceiptMismatchKind
) {
    XCTAssertEqual(receipt?.operationID, expected.operationID)
    XCTAssertEqual(receipt?.workspaceZone, expected.workspaceZone)
    switch kind {
    case .intent:
        XCTAssertNotEqual(receipt?.intentDigest, expected.intentDigest)
        XCTAssertEqual(receipt?.auditEventID, expected.auditEventID)
    case .auditEvent:
        XCTAssertEqual(receipt?.intentDigest, expected.intentDigest)
        XCTAssertNotEqual(receipt?.auditEventID, expected.auditEventID)
    }
}

final class FixtureCurrentContext: CurrentAuthorizationContextProviding, @unchecked Sendable {
    let value: AuthorizedOperationContext?
    init(_ value: AuthorizedOperationContext?) { self.value = value }
    func validateCurrent(_ context: AuthorizedOperationContext) async -> Bool { value == context }
}

final class FixtureArchiveExportSource: ArchiveExportSource, @unchecked Sendable {
    static let workspaceAssetID = ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000099")!)
    let account: AccountContext
    init(account: AccountContext) { self.account = account }
    func currentAccount() async throws -> AccountContext { account }
    func snapshot(for _: PersistenceNamespace) async throws -> ArchiveExportInput {
        let audit = try ArchiveAuditChain.encode(events: [Data("{\"event\":\"import\"}".utf8)])
        let path = "assets/photo.bin"
        let asset = ArchiveAssetPayload(
            id: Self.workspaceAssetID,
            stableID: ArchiveAsset.stableID(for: path),
            relativePath: path,
            contentType: "application/octet-stream",
            bytes: Data([0, 1, 2])
        )
        return ArchiveExportInput(
            recordCounts: [WorkspaceTransferRecordType.device.rawValue: 1], recordsJSONL: Data("{\"id\":\"device\"}\n".utf8), auditJSONL: audit.jsonl,
            auditHeadSHA256: audit.headSHA256, assets: [asset])
    }
}

final class FixtureArchiveReader: ArchiveEntryReader, @unchecked Sendable {
    private let chunks: [Data]
    private var index = 0
    init(data: Data) { chunks = stride(from: 0, to: data.count, by: 2).map { data.subdata(in: $0..<min($0 + 2, data.count)) } }
    func nextChunk() throws -> Data? {
        guard index < chunks.count else { return nil }
        defer { index += 1 }
        return chunks[index]
    }
}

final class FixtureArchiveSource: ArchiveEntrySource, @unchecked Sendable {
    private let metadata: [ArchiveEntryMetadata]
    private let bodies: [String: Data]
    init(entries: [String: Data]) {
        self.bodies = entries
        self.metadata = entries.keys.sorted().map { path in
            let body = entries[path] ?? Data()
            return ArchiveEntryMetadata(path: path, kind: .regularFile, uncompressedSize: body.count, compressedSize: body.count)
        }
    }
    init(metadata: [ArchiveEntryMetadata], bodies: [String: Data]) {
        self.metadata = metadata
        self.bodies = bodies
    }
    func entries() throws -> [ArchiveEntryMetadata] { metadata }
    func reader(for entry: ArchiveEntryMetadata) throws -> any ArchiveEntryReader { FixtureArchiveReader(data: bodies[entry.path] ?? Data()) }
}

final class MutableFixtureArchiveSource: ArchiveEntrySource, @unchecked Sendable {
    private var metadata: [ArchiveEntryMetadata] = []
    private var bodies: [String: Data] = [:]

    init(entries: [String: Data]) {
        replace(entries: entries)
    }

    func replace(entries: [String: Data]) {
        bodies = entries
        metadata = entries.keys.sorted().map { path in
            let body = entries[path] ?? Data()
            return ArchiveEntryMetadata(path: path, kind: .regularFile, uncompressedSize: body.count, compressedSize: body.count)
        }
    }

    func entries() throws -> [ArchiveEntryMetadata] { metadata }
    func reader(for entry: ArchiveEntryMetadata) throws -> any ArchiveEntryReader {
        FixtureArchiveReader(data: bodies[entry.path] ?? Data())
    }
}
