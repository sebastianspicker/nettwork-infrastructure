import CloudSync
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Pins ARCHITECTURE.md "Attachments and transfer": CSV import and archive
/// restore validate a canonical candidate, require an authorized session and
/// an empty, fresh target, and never stage or activate anything otherwise.
final class ProductionWorkspaceTransferAuthorityCharacterizationTests: XCTestCase {
    // MARK: CSV

    func testDryRunValidatesTheCanonicalCandidateAndReportsItsSize() async throws {
        let harness = try await TransferHarness.make()
        let records = harness.locationImports()

        let report = try await harness.authority.dryRun(records, in: harness.namespace)

        XCTAssertEqual(report.validatedRecordCount, records.count)
        XCTAssertEqual(report.canonicalSHA256, CanonicalImportDigest.digest(records: records))
        XCTAssertEqual(report.validatorVersion, WorkspaceTransferRecord.currentSchemaVersion)
        let committed = await harness.server.committed
        XCTAssertTrue(committed.isEmpty)
    }

    func testDryRunRejectsADanglingReferenceAndAForeignNamespace() async throws {
        let harness = try await TransferHarness.make()
        let orphan = ImportRecord(
            table: CSVTable.locations.rawValue,
            values: ["id": ObjectID().description, "name": "Orphan", "kind": "site", "parentID": ObjectID().description, "deletedAt": ""])

        await assertThrowsAny { try await harness.authority.dryRun([orphan], in: harness.namespace) }
        await assertThrows(ProductionWorkspaceTransferAuthorityError.namespaceMismatch) {
            try await harness.authority.dryRun(harness.locationImports(), in: ServiceFixture.namespace())
        }
    }

    func testWorkspaceEmptinessFollowsTheBootstrapSentinel() async throws {
        let harness = try await TransferHarness.make()

        await assertThrows(ProductionWorkspaceTransferAuthorityError.bootstrapSentinelMissing) {
            try await harness.authority.workspaceIsEmpty(in: harness.namespace)
        }
        try await harness.server.putSentinel(harness.namespace, lifecycle: .empty(epoch: 4))
        let empty = try await harness.authority.isFreshAuthenticatedTarget(in: harness.namespace)
        try await harness.server.putSentinel(harness.namespace, lifecycle: ServiceFixture.activeLifecycle())
        let active = try await harness.authority.workspaceIsEmpty(in: harness.namespace)

        XCTAssertTrue(empty)
        XCTAssertFalse(active)
    }

    func testCSVActivationIntoANonEmptyWorkspaceStagesNothing() async throws {
        let harness = try await TransferHarness.make()
        try await harness.server.putSentinel(harness.namespace, lifecycle: ServiceFixture.activeLifecycle())
        let records = harness.locationImports()
        let plan = try await harness.plan(for: records)

        await assertThrows(ProductionWorkspaceTransferAuthorityError.workspaceNotEmpty) {
            try await harness.authority.activateStagedCSV(
                records: records, plan: plan, requiringEmptyWorkspace: true, expectedReceipt: try CSVImportActivationReceipt.expected(for: plan))
        }
        await harness.assertNothingStaged()
    }

    func testCSVActivationRejectsAPlanThatDoesNotMatchItsInputBeforeAnyCloudRead() async throws {
        let harness = try await TransferHarness.make()
        try await harness.server.putSentinel(harness.namespace, lifecycle: .empty(epoch: 1))
        let records = harness.locationImports()
        let plan = try await harness.plan(for: records)
        let receipt = try CSVImportActivationReceipt.expected(for: plan)
        let otherPlan = try await harness.plan(for: records)

        await assertThrows(ProductionWorkspaceTransferAuthorityError.receiptMismatch) {
            try await harness.authority.activateStagedCSV(records: records, plan: plan, requiringEmptyWorkspace: false, expectedReceipt: receipt)
        }
        await assertThrows(ProductionWorkspaceTransferAuthorityError.receiptMismatch) {
            try await harness.authority.activateStagedCSV(
                records: Array(records.prefix(1)), plan: plan, requiringEmptyWorkspace: true, expectedReceipt: receipt)
        }
        await assertThrows(ProductionWorkspaceTransferAuthorityError.receiptMismatch) {
            try await harness.authority.activateStagedCSV(records: records, plan: otherPlan, requiringEmptyWorkspace: true, expectedReceipt: receipt)
        }
        let reads = await harness.server.readKeys
        XCTAssertEqual(reads, [], "A mismatched plan must fail before the Cloud target is consulted.")
        await harness.assertNothingStaged()
    }

    // MARK: Archive restore

    func testArchiveDryRunRejectsRestoringIntoItsSourceWorkspace() async throws {
        let harness = try await TransferHarness.make()
        let archive = try harness.emptyArchive(sourceWorkspaceID: harness.namespace.workspaceID)

        await assertThrows(ProductionWorkspaceTransferAuthorityError.archiveSourceMismatch) {
            try await harness.authority.dryRun(archive, for: harness.namespace)
        }
    }

    func testArchiveDryRunAcceptsAValidArchiveFromAnotherWorkspace() async throws {
        let harness = try await TransferHarness.make()
        let archive = try TransferHarness.archive(sourceWorkspaceID: ObjectID(), imports: harness.locationImports())

        try await harness.authority.dryRun(archive, for: harness.namespace)
        await assertThrowsAny { try await harness.authority.dryRun(try harness.emptyArchive(sourceWorkspaceID: ObjectID()), for: harness.namespace) }

        await harness.assertNothingStaged()
    }

    func testArchiveActivationRequiresTheReviewedRootProvenanceAndReceipt() async throws {
        let harness = try await TransferHarness.make()
        try await harness.server.putSentinel(harness.namespace, lifecycle: .empty(epoch: 1))
        let archive = try harness.emptyArchive(sourceWorkspaceID: ObjectID())
        let operationID = ObjectID()
        let receipt = try ProductionArchiveRestoreInput.memory(archive).expectedReceipt(target: harness.namespace, operationID: operationID)
        let foreign = ArchiveSourceProvenance(workspaceID: ObjectID(), containerIdentifier: "", zoneName: "", zoneOwnerRecordName: "")
        let cases: [(ArchiveSourceProvenance, String, OperationReceipt)] = [
            (archive.manifest.provenance, "0000", receipt),
            (foreign, archive.rootSHA256, receipt),
            (
                archive.manifest.provenance, archive.rootSHA256,
                try ProductionArchiveRestoreInput.memory(archive).expectedReceipt(
                    target: harness.namespace, operationID: ObjectID())
            ),
        ]

        for (source, root, expected) in cases {
            await assertThrows(ProductionWorkspaceTransferAuthorityError.archiveRootMismatch) {
                try await harness.authority.activateStagedArchive(
                    archive: archive, source: source, target: harness.namespace, expectedRootSHA256: root, operationID: operationID,
                    expectedReceipt: expected)
            }
        }
        let reads = await harness.server.readKeys
        XCTAssertEqual(reads, [])
        await harness.assertNothingStaged()
    }

    func testArchiveActivationIntoANonEmptyWorkspaceStagesNothing() async throws {
        let harness = try await TransferHarness.make()
        try await harness.server.putSentinel(harness.namespace, lifecycle: ServiceFixture.activeLifecycle())
        let archive = try harness.emptyArchive(sourceWorkspaceID: ObjectID())
        let operationID = ObjectID()

        await assertThrows(ProductionWorkspaceTransferAuthorityError.workspaceNotEmpty) {
            try await harness.authority.activateStagedArchive(
                archive: archive, source: archive.manifest.provenance, target: harness.namespace, expectedRootSHA256: archive.rootSHA256,
                operationID: operationID,
                expectedReceipt: try ProductionArchiveRestoreInput.memory(archive).expectedReceipt(target: harness.namespace, operationID: operationID))
        }
        await harness.assertNothingStaged()
    }

    // MARK: Export

    func testSnapshotExportsTheCanonicalMirrorWithAnEmptyAuditChain() async throws {
        let harness = try await TransferHarness.make()
        let hierarchy = HierarchyFixture()
        try await ServiceFixture.seed(harness.store, namespace: harness.namespace, records: try hierarchy.records(in: harness.namespace))

        let snapshot = try await harness.authority.snapshot(for: harness.namespace)

        XCTAssertEqual(snapshot.recordCounts.values.reduce(0, +), hierarchy.locations.count + 1)
        XCTAssertEqual(snapshot.auditHeadSHA256, ArchiveAuditChain.emptyHeadSHA256)
        XCTAssertTrue(snapshot.assets.isEmpty)
        XCTAssertEqual(try WorkspaceTransferJSONL.decode(snapshot.recordsJSONL).count, hierarchy.locations.count + 1)
    }
}

/// Counts staged-transfer writes; any call means the authority staged data.
actor RecordingBatchTransport: CloudConditionalBatchTransport {
    private(set) var callCount = 0

    func saveConditionally(_: AtomicCloudMutation) async throws -> CloudConditionalBatchResult {
        callCount += 1
        throw ServiceTestError(reason: "staging is not expected in these tests")
    }
}

struct EmptyArchiveAssetSource: ProductionArchiveAssetSource {
    func assets(in _: PersistenceNamespace) async throws -> [ProductionArchiveAsset] { [] }
}

struct TransferHarness {
    let session: SessionHarness
    let server: FakeCloudServer
    let transport: RecordingBatchTransport
    let store: SwiftDataPersistenceStore
    let authority: ProductionWorkspaceTransferAuthority

    var namespace: PersistenceNamespace { session.namespace }

    static func make() async throws -> TransferHarness {
        let session = try await SessionHarness.make()
        let server = FakeCloudServer()
        let transport = RecordingBatchTransport()
        let store = try ServiceFixture.makeStore()
        _ = await store.activateLease(for: session.namespace)
        let authority = ProductionWorkspaceTransferAuthority(
            account: session.account, persistence: store, sessionAuthorizer: session.authorizer, exactRecords: server,
            stagedTransfers: CloudStagedTransferRepository(transport: transport, reader: server), mutations: server,
            assetSource: EmptyArchiveAssetSource())
        return TransferHarness(session: session, server: server, transport: transport, store: store, authority: authority)
    }

    /// A workspace root and one site, as exact v1 CSV location rows.
    func locationImports() -> [ImportRecord] {
        let workspaceID = ObjectID()
        let table = CSVTable.locations.rawValue
        return [
            ImportRecord(table: table, values: ["id": workspaceID.description, "name": "Example", "kind": "workspace", "parentID": "", "deletedAt": ""]),
            ImportRecord(
                table: table,
                values: ["id": ObjectID().description, "name": "Main site", "kind": "site", "parentID": workspaceID.description, "deletedAt": ""]),
        ]
    }

    func plan(for records: [ImportRecord]) async throws -> ImportPlan {
        let report = try await authority.dryRun(records, in: namespace)
        return try ImportPlan(
            namespace: namespace, canonicalSHA256: report.canonicalSHA256, recordCounts: [CSVTable.locations.rawValue: records.count],
            totalRecordCount: records.count, stagingGeneration: 1, operationID: ObjectID(), dryRunReport: report)
    }

    /// Writes and verifies a complete archive without records, audit or assets.
    func emptyArchive(sourceWorkspaceID: ObjectID) throws -> VerifiedArchive {
        try Self.archive(sourceWorkspaceID: sourceWorkspaceID, imports: [])
    }

    /// Writes and verifies a complete archive holding the canonical transfer
    /// records reconstructed from `imports`, with no audit events or assets.
    static func archive(sourceWorkspaceID: ObjectID, imports: [ImportRecord]) throws -> VerifiedArchive {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transfer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transferRecords = try WorkspaceTransferRecordReconstruction.records(from: imports)
        let records = imports.isEmpty ? Data() : try WorkspaceTransferJSONL.encode(transferRecords)
        let recordsDigest = CloudRecordAssetDescriptor.sha256(for: records)
        let digest = CloudRecordAssetDescriptor.sha256(for: Data())
        let rootDigest = ArchiveVerifier.rootDigest(for: [
            ArchiveLayout.recordsPath: ArchiveDigest(size: records.count, sha256: recordsDigest),
            ArchiveLayout.auditPath: ArchiveDigest(size: 0, sha256: digest),
        ])
        let manifest = ArchiveManifest(
            workspaceID: sourceWorkspaceID, createdAt: ServiceFixture.epoch,
            recordCounts: Dictionary(grouping: transferRecords, by: { $0.recordType.rawValue }).mapValues(\.count), assets: [], auditRecordCount: 0,
            recordsSHA256: recordsDigest, auditSHA256: digest, auditHeadSHA256: ArchiveAuditChain.emptyHeadSHA256, rootSHA256: rootDigest)
        let completion = ArchiveCompletionMarker(
            rootSHA256: rootDigest, manifestCommitmentSHA256: try ArchiveManifestCommitment.digest(for: manifest), completedAt: ServiceFixture.epoch)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for (path, data) in [
            (ArchiveLayout.manifestPath, try encoder.encode(manifest)), (ArchiveLayout.completionPath, try encoder.encode(completion)),
            (ArchiveLayout.recordsPath, records), (ArchiveLayout.auditPath, Data()),
        ] {
            try data.write(to: root.appendingPathComponent(path))
        }
        return try ArchiveVerifier().verify(source: FileBackedArchiveEntrySource(root: root))
    }

    func assertNothingStaged(file: StaticString = #filePath, line: UInt = #line) async {
        let stagedWrites = await transport.callCount
        let committed = await server.committed
        XCTAssertEqual(stagedWrites, 0, "No staged transfer member may be written.", file: file, line: line)
        XCTAssertTrue(committed.isEmpty, "No activation may be committed.", file: file, line: line)
    }
}
