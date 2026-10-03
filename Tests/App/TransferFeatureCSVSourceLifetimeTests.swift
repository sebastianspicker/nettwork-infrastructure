import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

@MainActor
final class TransferFeatureCSVSourceLifetimeTests: XCTestCase {
    func testSuccessfulDryRunRetainsSourceUntilExplicitCancel() async throws {
        let authorization = makeImportAuthorization()
        let plan = try makePlan(authorization)
        let source = TrackingCSVImportSource()
        let model = TransferFeatureViewModel(
            service: CSVLifetimeTransferService(plan: plan),
            csvExporter: UnusedCSVWorkspaceExporter())

        await model.dryRunCSV(source: source, authorization: authorization)
        XCTAssertEqual(source.closeCount, 0)

        model.cancelCSVImport()
        XCTAssertEqual(source.closeCount, 1)
    }

    func testReplacementClosesPreviousSourceAndActivationClosesReplacement() async throws {
        let authorization = makeImportAuthorization()
        let plan = try makePlan(authorization)
        let first = TrackingCSVImportSource()
        let second = TrackingCSVImportSource()
        let model = TransferFeatureViewModel(
            service: CSVLifetimeTransferService(plan: plan),
            csvExporter: UnusedCSVWorkspaceExporter())

        await model.dryRunCSV(source: first, authorization: authorization)
        await model.dryRunCSV(source: second, authorization: authorization)
        XCTAssertEqual(first.closeCount, 1)
        XCTAssertEqual(second.closeCount, 0)

        await model.activateCSV(expectedPlan: plan)
        XCTAssertEqual(second.closeCount, 1)
    }

    private func makeImportAuthorization() -> AuthorizedOperationContext {
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "owner", workspaceID: ObjectID(),
            zoneName: "workspace", zoneOwnerRecordName: "owner",
            sessionGeneration: 1)
        let account = AccountContext(
            namespace: namespace, databaseScope: .ownerPrivate,
            sharePermission: .owner, verifiedAt: .distantPast)
        return AuthorizedOperationContext(
            operationID: ObjectID(), account: account,
            actor: ActorContext(
                cloudKitUserRecordName: "owner", role: .administrator,
                installationID: "test", sessionGeneration: 1),
            action: .importCSV)
    }

    private func makePlan(
        _ authorization: AuthorizedOperationContext
    ) throws -> ImportPlan {
        try ImportPlan(
            namespace: authorization.account.namespace,
            canonicalSHA256: String(repeating: "a", count: 64),
            recordCounts: [:], totalRecordCount: 0, stagingGeneration: 1,
            operationID: authorization.operationID,
            dryRunReport: ImportDryRunReport(
                canonicalSHA256: String(repeating: "a", count: 64),
                validatorVersion: 1, validatedRecordCount: 0))
    }
}

private final class TrackingCSVImportSource:
    CSVImportSource, CSVImportSourceAccessLifetime, @unchecked Sendable
{
    private(set) var closeCount = 0
    func fileMetadata() throws -> [CSVImportFileMetadata] { [] }
    func openFile(
        _ file: CSVImportFileMetadata
    ) throws -> AnyCSVByteChunkSource {
        AnyCSVByteChunkSource(DataCSVByteChunkSource(data: Data()))
    }
    func close() { closeCount += 1 }
}

@MainActor
private final class CSVLifetimeTransferService: TransferFeatureService {
    let plan: ImportPlan
    init(plan: ImportPlan) { self.plan = plan }
    func dryRunCSV(
        _ source: any CSVImportSource,
        authorization: AuthorizedOperationContext
    ) async throws -> ImportPlan { plan }
    func activateCSV(
        _ plan: ImportPlan, source: any CSVImportSource,
        authorization: AuthorizedOperationContext
    ) async throws {}
    func exportArchive(
        authorization: AuthorizedOperationContext
    ) async throws -> ArchiveExportDocument { fatalError("Unused") }
    func validateArchiveExportAuthorization(
        _ authorization: AuthorizedOperationContext
    ) async throws { fatalError("Unused") }
    func verifyArchive(
        _ source: any ArchiveEntrySource,
        authorization: AuthorizedOperationContext
    ) async throws -> FileBackedArchiveRestorePreview { fatalError("Unused") }
    func restoreArchive(
        _ archive: FileBackedVerifiedArchive, approval: ArchiveRestoreApproval,
        authorization: AuthorizedOperationContext
    ) async throws { fatalError("Unused") }
}

private struct UnusedCSVWorkspaceExporter: CSVWorkspaceExporting {
    func exportCSV(
        authorization: AuthorizedOperationContext
    ) async throws -> CSVWorkspaceExportDocument { fatalError("Unused") }
    func validateCSVExportAuthorization(
        _ authorization: AuthorizedOperationContext
    ) async throws { fatalError("Unused") }
}

@MainActor
final class TransferFeatureArchiveAuthorizationTests: XCTestCase {
    func testPreparedArchiveIsClearedWhenHandoffAuthorizationIsRevoked() async throws {
        let authorization = makeArchiveAuthorization()
        let service = ArchiveAuthorizationTransferService(document: makeArchiveDocument(authorization))
        let model = TransferFeatureViewModel(service: service, csvExporter: UnusedCSVWorkspaceExporter())
        await model.exportArchive(authorization: authorization)
        service.shouldRejectValidation = true

        do {
            _ = try await model.prepareArchiveExportHandoff()
            XCTFail("Expected revoked archive handoff to fail.")
        } catch ArchiveAuthorizationTestError.revoked {
            // Expected.
        }
        if case .idle = model.archiveState {
        } else {
            XCTFail("A rejected handoff must clear the cached archive.")
        }
    }

    func testPreparedArchiveHandoffUsesCurrentAuthorization() async throws {
        let authorization = makeArchiveAuthorization()
        let service = ArchiveAuthorizationTransferService(document: makeArchiveDocument(authorization))
        let model = TransferFeatureViewModel(service: service, csvExporter: UnusedCSVWorkspaceExporter())
        await model.exportArchive(authorization: authorization)

        let document = try await model.prepareArchiveExportHandoff()

        XCTAssertEqual(document.manifest.workspaceID, authorization.account.namespace.workspaceID)
        XCTAssertEqual(service.validationCount, 1)
    }

    func testArchiveRevokedWhileDestinationIsOpenFailsBeforePayloadPublication() async throws {
        let authorization = makeArchiveAuthorization()
        let service = ArchiveAuthorizationTransferService(document: makeArchiveDocument(authorization))
        let model = TransferFeatureViewModel(service: service, csvExporter: UnusedCSVWorkspaceExporter())
        await model.exportArchive(authorization: authorization)
        try await model.validateArchiveExportHandoff()
        service.shouldRejectValidation = true

        do {
            _ = try await model.prepareArchiveExportHandoff()
            XCTFail("Expected final archive publication authorization to fail.")
        } catch ArchiveAuthorizationTestError.revoked {
            // Expected.
        }
        if case .idle = model.archiveState {
        } else {
            XCTFail("A rejected final publication must clear the cached archive.")
        }
    }

    func testAuthorizedArchivePublicationReplacesPlaceholderPackage() throws {
        let authorization = makeArchiveAuthorization()
        let payload = Data("verified archive".utf8)
        let document = makeArchiveDocument(
            authorization,
            entries: [ArchiveLayout.recordsPath: payload]
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("nettworkarchive")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: destination) }

        try NettworkArchiveDocument.publish(document, to: destination)

        XCTAssertEqual(
            try Data(contentsOf: destination.appendingPathComponent(ArchiveLayout.recordsPath)),
            payload
        )
    }

    func testArchivePlaceholderPreservesExistingDestinationContents() throws {
        let existingPayload = Data("existing backup".utf8)
        let existingFile = FileWrapper(regularFileWithContents: existingPayload)
        let document = NettworkArchiveDocument()

        let placeholder = document.placeholderWrapper(preserving: existingFile)

        XCTAssertTrue(placeholder === existingFile)
        XCTAssertEqual(placeholder.regularFileContents, existingPayload)
    }

    private func makeArchiveAuthorization() -> AuthorizedOperationContext {
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "owner",
            workspaceID: ObjectID(),
            zoneName: "workspace",
            zoneOwnerRecordName: "owner",
            sessionGeneration: 1
        )
        let account = AccountContext(
            namespace: namespace,
            databaseScope: .ownerPrivate,
            sharePermission: .owner,
            verifiedAt: .distantPast
        )
        return AuthorizedOperationContext(
            operationID: ObjectID(),
            account: account,
            actor: ActorContext(
                cloudKitUserRecordName: "owner",
                role: .administrator,
                installationID: "test",
                sessionGeneration: 1
            ),
            action: .exportArchive
        )
    }

    private func makeArchiveDocument(
        _ authorization: AuthorizedOperationContext,
        entries: [String: Data] = [:]
    ) -> ArchiveExportDocument {
        let root = String(repeating: "a", count: 64)
        return ArchiveExportDocument(
            manifest: ArchiveManifest(
                workspaceID: authorization.account.namespace.workspaceID,
                recordCounts: [:],
                auditRecordCount: 0,
                rootSHA256: root
            ),
            completionMarker: ArchiveCompletionMarker(
                rootSHA256: root,
                manifestCommitmentSHA256: String(repeating: "b", count: 64)
            ),
            entries: entries
        )
    }
}

private enum ArchiveAuthorizationTestError: Error { case revoked }

@MainActor
private final class ArchiveAuthorizationTransferService: TransferFeatureService {
    let document: ArchiveExportDocument
    var shouldRejectValidation = false
    private(set) var validationCount = 0

    init(document: ArchiveExportDocument) { self.document = document }

    func dryRunCSV(
        _ source: any CSVImportSource,
        authorization: AuthorizedOperationContext
    ) async throws -> ImportPlan { fatalError("Unused") }
    func activateCSV(
        _ plan: ImportPlan,
        source: any CSVImportSource,
        authorization: AuthorizedOperationContext
    ) async throws { fatalError("Unused") }
    func exportArchive(authorization: AuthorizedOperationContext) async throws -> ArchiveExportDocument { document }
    func validateArchiveExportAuthorization(_ authorization: AuthorizedOperationContext) async throws {
        validationCount += 1
        if shouldRejectValidation { throw ArchiveAuthorizationTestError.revoked }
    }
    func verifyArchive(
        _ source: any ArchiveEntrySource,
        authorization: AuthorizedOperationContext
    ) async throws -> FileBackedArchiveRestorePreview { fatalError("Unused") }
    func restoreArchive(
        _ archive: FileBackedVerifiedArchive,
        approval: ArchiveRestoreApproval,
        authorization: AuthorizedOperationContext
    ) async throws { fatalError("Unused") }
}
