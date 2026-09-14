import ContentSafety
import ImportExport

struct ProductionRuntimeAttachmentGraph {
    let staging: FileBackedPrivateAttachmentStaging
    let contentSafety: ContentSafetyService
    let authority: ProductionAttachmentEvidenceAuthority
    let service: ProductionAttachmentEvidenceFeatureService
}

struct ProductionRuntimeTransferGraph {
    let correctiveBuilder: ProductionCorrectiveDraftBuilder
    let auditExporter: FileBackedProductionAuditExporter
    let authority: any ProductionWorkspaceTransferAuthorityProviding
    let csvStagingStore: FileBackedCSVImportStagingStore
    let archiveRestoreStore: FileBackedArchiveRestoreStore
    let service: ProductionTransferFeatureService
}

extension ProductionRuntimeAssembly {
    static func makeRuntimeAttachmentGraph(
        _ input: OrganizationInput, foundation: ProductionRuntimeFoundation, cloud: ProductionRuntimeCloudGraph
    ) throws -> ProductionRuntimeAttachmentGraph {
        let staging = try FileBackedPrivateAttachmentStaging(
            root: input.workspaceStorage.attachmentStagingDirectory,
            lifetime: input.workspaceStorage.attachmentStagingLifetime,
            protection: input.workspaceStorage.attachmentStagingProtection
        )
        let contentSafety = ContentSafetyService(decoder: PlatformContentSanitizingDecoder(), staging: staging, currentContext: foundation.sessionAuthorizer)
        let authority = ProductionAttachmentEvidenceAuthority(
            sessionAuthorizer: foundation.sessionAuthorizer, exactRecords: cloud.transport,
            mutations: cloud.mutationRepository, persistence: foundation.persistence, policy: input.operationGovernance.attachmentPolicy)
        let service = ProductionAttachmentEvidenceFeatureService(
            account: input.cloudWorkspace.account, contentSafety: contentSafety,
            bindingService: AuthorizedAttachmentEvidenceBindingService(
                authority: authority, staging: staging,
                currentContext: foundation.sessionAuthorizer), operationBoundary: foundation.operationBoundary)
        return ProductionRuntimeAttachmentGraph(staging: staging, contentSafety: contentSafety, authority: authority, service: service)
    }

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
