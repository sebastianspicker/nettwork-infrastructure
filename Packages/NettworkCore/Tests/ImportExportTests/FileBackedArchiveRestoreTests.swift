import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import ImportExport

extension ImportExportSecurityTests {
    func testFileBackedVerifierBindsSameApprovalAndReceiptWithoutMaterializingAssets() async throws {
        let sourceAccount = fixtureAccount()
        let exportContext = fixtureContext(account: sourceAccount, action: .exportArchive)
        let document = try await AuthorizedArchiveExportService(
            source: FixtureArchiveExportSource(account: sourceAccount),
            currentContext: FixtureCurrentContext(exportContext)
        ).makeDocument(context: exportContext, createdAt: .distantPast)
        let target = fixtureAccount()
        let restoreContext = fixtureContext(account: target, action: .restoreArchive)
        let stagingRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }

        let filePreview = try ArchiveVerifier().verifyFileBackedForRestore(
            source: FixtureArchiveSource(entries: document.entries),
            stagingRoot: stagingRoot, authorization: restoreContext)
        defer { filePreview.discardIfUnadopted() }
        let memoryPreview = try ArchiveVerifier().verifyForRestore(
            source: FixtureArchiveSource(entries: document.entries),
            authorization: restoreContext)

        XCTAssertEqual(filePreview.approval, memoryPreview.approval)
        XCTAssertEqual(
            try ArchiveRestoreActivationReceipt.expected(
                for: filePreview.archive, target: target.namespace,
                operationID: restoreContext.operationID),
            try ArchiveRestoreActivationReceipt.expected(
                for: memoryPreview.archive, target: target.namespace,
                operationID: restoreContext.operationID))
        let asset = try XCTUnwrap(filePreview.archive.manifest.assets.first)
        let descriptor = try filePreview.archive.assetDescriptor(
            for: asset, fieldName: "payload")
        guard case .durableFile = descriptor.storage else {
            return XCTFail("Expected durable file capability")
        }
        XCTAssertEqual(try descriptor.validatedBytes(), Data([0, 1, 2]))
    }

    func testFileBackedDescriptorDetectsTamperAndExplicitDiscardRemovesPreview() async throws {
        let account = fixtureAccount()
        let exportContext = fixtureContext(account: account, action: .exportArchive)
        let document = try await AuthorizedArchiveExportService(
            source: FixtureArchiveExportSource(account: account),
            currentContext: FixtureCurrentContext(exportContext)
        ).makeDocument(context: exportContext, createdAt: .distantPast)
        let target = fixtureAccount()
        let context = fixtureContext(account: target, action: .restoreArchive)
        let stagingRoot = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: stagingRoot) }
        let preview = try ArchiveVerifier().verifyFileBackedForRestore(
            source: FixtureArchiveSource(entries: document.entries),
            stagingRoot: stagingRoot, authorization: context)
        let asset = try XCTUnwrap(preview.archive.manifest.assets.first)
        let descriptor = try preview.archive.assetDescriptor(for: asset, fieldName: "payload")
        guard case let .durableFile(url) = descriptor.storage else {
            return XCTFail("Expected durable file capability")
        }

        try Data("tampered".utf8).write(to: url)
        XCTAssertThrowsError(try preview.archive.readEntry(at: asset.relativePath))
        preview.discardIfUnadopted()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testAdoptedPreviewCannotDeleteStorePayloadBeforeActivation() async throws {
        let sourceAccount = fixtureAccount()
        let exportContext = fixtureContext(account: sourceAccount, action: .exportArchive)
        let document = try await AuthorizedArchiveExportService(
            source: FixtureArchiveExportSource(account: sourceAccount),
            currentContext: FixtureCurrentContext(exportContext)
        ).makeDocument(context: exportContext, createdAt: .distantPast)
        let target = fixtureAccount()
        let context = fixtureContext(account: target, action: .restoreArchive)
        let root = temporaryDirectory()
        let verification = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: verification)
        }
        let preview = try ArchiveVerifier().verifyFileBackedForRestore(
            source: FixtureArchiveSource(entries: document.entries),
            stagingRoot: verification, authorization: context)
        let authority = FileBackedTestRestoreAuthority(account: target)
        let store = FileBackedArchiveRestoreStore(root: root, authority: authority)
        let staging = try await store.createRestoreStaging(
            source: preview.archive.manifest.provenance, target: target.namespace,
            operationID: context.operationID)
        try await store.stage(preview.archive, in: staging)
        preview.discardIfUnadopted()
        let expected = try ArchiveRestoreActivationReceipt.expected(
            for: preview.archive, target: target.namespace,
            operationID: context.operationID)

        let receipt = try await store.activateRestore(
            staging, expectedFreshTarget: target.namespace,
            operationID: context.operationID, expectedReceipt: expected)
        XCTAssertEqual(receipt, expected)
    }

    func testCancellationRemovesPartiallyCopiedVerificationDirectory() async throws {
        let account = fixtureAccount()
        let context = fixtureContext(account: account, action: .exportArchive)
        let document = try await AuthorizedArchiveExportService(
            source: FixtureArchiveExportSource(account: account),
            currentContext: FixtureCurrentContext(context)
        ).makeDocument(context: context, createdAt: .distantPast)
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task.detached {
            try ArchiveVerifier().verifyFileBacked(
                source: CancellingArchiveSource(entries: document.entries),
                stagingRoot: root)
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
        let remaining = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil)
        XCTAssertTrue(remaining.isEmpty)
    }

    func testVerifiedArchiveTamperIsTerminalForDurableStagingCleanup() {
        XCTAssertTrue(
            StagedTransferCleanupClassifier.disposition(
                for: ArchiveValidationError.hashMismatch("records.jsonl")
            )
            .discardsStaging)
        XCTAssertEqual(
            StagedTransferCleanupClassifier.disposition(
                for: ImportAuthorizationError.staleContext),
            .retainRetryable)
    }

    func testAuthorizedFileBackedRestoreReopensDurableStageAfterRetryableFailure() async throws {
        let fixture = try await makeRestoreFixture()
        let root = temporaryDirectory()
        let verification = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: verification)
        }
        let authority = FileBackedTestRestoreAuthority(
            account: fixture.target, fileActivationFailures: 1)
        let firstStore = FileBackedArchiveRestoreStore(root: root, authority: authority)
        let firstService = AuthorizedArchiveRestoreService(
            store: firstStore,
            currentContext: FixtureCurrentContext(fixture.context))
        let firstPreview = try ArchiveVerifier().verifyFileBackedForRestore(
            source: FixtureArchiveSource(entries: fixture.document.entries),
            stagingRoot: verification, authorization: fixture.context)
        let operationDirectory = root.appendingPathComponent(
            fixture.context.operationID.description, isDirectory: true)

        do {
            _ = try await firstService.restore(
                archive: firstPreview.archive, approval: firstPreview.approval,
                context: fixture.context)
            XCTFail("Expected retryable authority failure")
        } catch is RetryableArchiveAuthorityError {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: operationDirectory.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: operationDirectory.appendingPathComponent("staging.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: operationDirectory.appendingPathComponent("archive/manifest.json").path))

        let reopenedStore = FileBackedArchiveRestoreStore(root: root, authority: authority)
        let reopenedService = AuthorizedArchiveRestoreService(
            store: reopenedStore,
            currentContext: FixtureCurrentContext(fixture.context))
        let retryPreview = try ArchiveVerifier().verifyFileBackedForRestore(
            source: FixtureArchiveSource(entries: fixture.document.entries),
            stagingRoot: verification, authorization: fixture.context)
        let expected = try ArchiveRestoreActivationReceipt.expected(
            for: retryPreview.archive, target: fixture.target.namespace,
            operationID: fixture.context.operationID)

        let receipt = try await reopenedService.restore(
            archive: retryPreview.archive, approval: retryPreview.approval,
            context: fixture.context)
        let activationAttempts = await authority.fileActivationAttempts
        XCTAssertEqual(receipt, expected)
        XCTAssertEqual(activationAttempts, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: operationDirectory.path))
    }

    func testAuthorizedFileBackedRestoreDiscardsStageAfterAdoptedByteTamper() async throws {
        let fixture = try await makeRestoreFixture()
        let root = temporaryDirectory()
        let verification = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: verification)
        }
        let authority = FileBackedTestRestoreAuthority(account: fixture.target)
        let baseStore = FileBackedArchiveRestoreStore(root: root, authority: authority)
        let store = TamperingArchiveRestoreStore(base: baseStore)
        let service = AuthorizedArchiveRestoreService(
            store: store,
            currentContext: FixtureCurrentContext(fixture.context))
        let preview = try ArchiveVerifier().verifyFileBackedForRestore(
            source: FixtureArchiveSource(entries: fixture.document.entries),
            stagingRoot: verification, authorization: fixture.context)
        let operationDirectory = root.appendingPathComponent(
            fixture.context.operationID.description, isDirectory: true)

        do {
            _ = try await service.restore(
                archive: preview.archive, approval: preview.approval,
                context: fixture.context)
            XCTFail("Expected staged payload tamper rejection")
        } catch is ArchiveValidationError {}
        let activationAttempts = await authority.fileActivationAttempts
        XCTAssertEqual(activationAttempts, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: operationDirectory.path))
    }

    private func makeRestoreFixture() async throws -> (
        document: ArchiveExportDocument,
        target: AccountContext,
        context: AuthorizedOperationContext
    ) {
        let source = fixtureAccount()
        let exportContext = fixtureContext(account: source, action: .exportArchive)
        let document = try await AuthorizedArchiveExportService(
            source: FixtureArchiveExportSource(account: source),
            currentContext: FixtureCurrentContext(exportContext)
        ).makeDocument(context: exportContext, createdAt: .distantPast)
        let target = fixtureAccount()
        return (
            document, target,
            fixtureContext(account: target, action: .restoreArchive)
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
    }
}

private struct CancellingArchiveSource: ArchiveEntrySource, @unchecked Sendable {
    let values: [String: Data]
    init(entries: [String: Data]) { values = entries }
    func entries() throws -> [ArchiveEntryMetadata] {
        values.map { path, data in
            .init(
                path: path, kind: .regularFile,
                uncompressedSize: data.count,
                compressedSize: max(1, data.count))
        }
    }
    func reader(
        for entry: ArchiveEntryMetadata
    ) throws -> any ArchiveEntryReader {
        guard let data = values[entry.path] else {
            throw ArchiveValidationError.unknownEntry(entry.path)
        }
        return CancellingArchiveReader(data: data)
    }
}

private final class CancellingArchiveReader:
    ArchiveEntryReader, @unchecked Sendable
{
    private let data: Data
    private var returned = false
    init(data: Data) { self.data = data }
    func nextChunk() throws -> Data? {
        guard !returned else { return nil }
        returned = true
        withUnsafeCurrentTask { $0?.cancel() }
        return data
    }
}

private actor FileBackedTestRestoreAuthority:
    FileBackedArchiveRestoreActivationAuthority
{
    let account: AccountContext
    private var fileActivationFailures: Int
    private(set) var fileActivationAttempts = 0
    init(account: AccountContext, fileActivationFailures: Int = 0) {
        self.account = account
        self.fileActivationFailures = fileActivationFailures
    }
    func currentAccount() async throws -> AccountContext { account }
    func isFreshAuthenticatedTarget(in namespace: PersistenceNamespace) async throws -> Bool {
        namespace == account.namespace
    }
    func dryRun(_ archive: VerifiedArchive, for target: PersistenceNamespace) async throws {}
    func dryRun(
        _ archive: FileBackedVerifiedArchive, for target: PersistenceNamespace
    ) async throws {}
    func activateStagedArchive(
        archive: VerifiedArchive, source: ArchiveSourceProvenance,
        target: PersistenceNamespace, expectedRootSHA256: String,
        operationID: ObjectID, expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt { expectedReceipt }
    func activateStagedArchive(
        archive: FileBackedVerifiedArchive, source: ArchiveSourceProvenance,
        target: PersistenceNamespace, expectedRootSHA256: String,
        operationID: ObjectID, expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        fileActivationAttempts += 1
        guard fileActivationFailures == 0 else {
            fileActivationFailures -= 1
            throw RetryableArchiveAuthorityError.transport
        }
        return expectedReceipt
    }
}

private enum RetryableArchiveAuthorityError: Error {
    case transport
}

private actor TamperingArchiveRestoreStore: ArchiveRestoreStore {
    let base: FileBackedArchiveRestoreStore
    init(base: FileBackedArchiveRestoreStore) { self.base = base }

    func currentAccount() async throws -> AccountContext {
        try await base.currentAccount()
    }
    func isFreshAuthenticatedTarget(
        in namespace: PersistenceNamespace
    ) async throws -> Bool {
        try await base.isFreshAuthenticatedTarget(in: namespace)
    }
    func dryRun(
        _ archive: VerifiedArchive, for target: PersistenceNamespace
    ) async throws {
        try await base.dryRun(archive, for: target)
    }
    func dryRun(
        _ archive: FileBackedVerifiedArchive,
        for target: PersistenceNamespace
    ) async throws {
        try await base.dryRun(archive, for: target)
    }
    func createRestoreStaging(
        source: ArchiveSourceProvenance, target: PersistenceNamespace,
        operationID: ObjectID
    ) async throws -> ImportStagingHandle {
        try await base.createRestoreStaging(
            source: source, target: target, operationID: operationID)
    }
    func stage(
        _ archive: VerifiedArchive, in staging: ImportStagingHandle
    ) async throws {
        try await base.stage(archive, in: staging)
    }
    func stage(
        _ archive: FileBackedVerifiedArchive, in staging: ImportStagingHandle
    ) async throws {
        try await base.stage(archive, in: staging)
        let asset = try XCTUnwrap(archive.manifest.assets.first)
        let descriptor = try archive.assetDescriptor(for: asset, fieldName: "payload")
        guard case let .durableFile(url) = descriptor.storage else {
            throw ArchiveValidationError.manifestMismatch
        }
        try Data([9, 9, 9]).write(to: url)
    }
    func activateRestore(
        _ staging: ImportStagingHandle,
        expectedFreshTarget: PersistenceNamespace, operationID: ObjectID,
        expectedReceipt: OperationReceipt
    ) async throws -> OperationReceipt {
        try await base.activateRestore(
            staging, expectedFreshTarget: expectedFreshTarget,
            operationID: operationID, expectedReceipt: expectedReceipt)
    }
    func discardRestore(_ staging: ImportStagingHandle) async {
        await base.discardRestore(staging)
    }
}
