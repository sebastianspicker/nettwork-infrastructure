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
