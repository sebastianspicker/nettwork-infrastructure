import ContentSafety
import ImportExport
import WorkspaceServices

/// The transfer actor remains behind this narrow retained seam because it owns
/// staged payload activation. Production assembly constructs the concrete
/// authority itself; organization input cannot substitute a permissive writer.
protocol ProductionWorkspaceTransferAuthorityProviding: AnyObject,
    CSVImportActivationAuthority,
    ArchiveExportSource,
    ArchiveRestoreActivationAuthority,
    TransferCurrentAccountProviding
{}

extension ProductionWorkspaceTransferAuthority: ProductionWorkspaceTransferAuthorityProviding {}

struct ProductionRuntimeTransferGraph {
    let correctiveBuilder: ProductionCorrectiveDraftBuilder
    let auditExporter: FileBackedProductionAuditExporter
    let authority: any ProductionWorkspaceTransferAuthorityProviding
    let csvStagingStore: FileBackedCSVImportStagingStore
    let archiveRestoreStore: FileBackedArchiveRestoreStore
    let service: ProductionTransferFeatureService
}

extension ProductionRuntimeAssembly {
    static func makeRuntimeTransferGraph(
        _ input: OrganizationInput, foundation: ProductionRuntimeFoundation, cloud: ProductionRuntimeCloudGraph
    ) -> ProductionRuntimeTransferGraph {
        let correctiveBuilder = ProductionCorrectiveDraftBuilder(
            persistence: foundation.persistence, resolutionProvider: input.operationGovernance.correctiveResolutionProvider)
        let auditExporter = FileBackedProductionAuditExporter(
            account: input.cloudWorkspace.account, persistence: foundation.persistence,
            privateRoot: input.workspaceStorage.auditPrivateDirectory, destination: input.operationGovernance.auditDestination)
        let authority = ProductionWorkspaceTransferAuthority(
            account: input.cloudWorkspace.account, persistence: foundation.persistence,
            sessionAuthorizer: foundation.sessionAuthorizer, exactRecords: cloud.transport, stagedTransfers: cloud.stagedTransferRepository,
            mutations: cloud.mutationRepository, assetSource: SwiftDataProductionArchiveAssetSource(persistence: foundation.persistence))
        let csvStore = FileBackedCSVImportStagingStore(root: input.workspaceStorage.csvStagingDirectory, authority: authority)
        let archiveStore = FileBackedArchiveRestoreStore(root: input.workspaceStorage.archiveRestoreStagingDirectory, authority: authority)
        let service = ProductionTransferFeatureService(
            stagingGeneration: DeterministicImportStagingGenerationProvider(),
            currentAccount: authority, csvImport: AuthorizedCSVImportService(store: csvStore, currentContext: foundation.sessionAuthorizer),
            archiveExport: AuthorizedArchiveExportService(source: authority, currentContext: foundation.sessionAuthorizer),
            archiveRestore: AuthorizedArchiveRestoreService(
                store: archiveStore, currentContext: foundation.sessionAuthorizer,
                verifier: input.operationGovernance.archiveVerifier), archiveVerifier: input.operationGovernance.archiveVerifier,
            archiveVerificationStagingRoot: input.workspaceStorage.archiveRestoreStagingDirectory.appendingPathComponent(".verification", isDirectory: true),
            operationBoundary: foundation.operationBoundary)
        return ProductionRuntimeTransferGraph(
            correctiveBuilder: correctiveBuilder, auditExporter: auditExporter, authority: authority,
            csvStagingStore: csvStore, archiveRestoreStore: archiveStore, service: service)
    }
}
