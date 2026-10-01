import ContentSafety
import WorkspaceServices

struct ProductionRuntimeAttachmentGraph {
    let staging: FileBackedPrivateAttachmentStaging
    let contentSafety: ContentSafetyService
    let authority: ProductionAttachmentEvidenceAuthority
    let service: ProductionAttachmentEvidenceFeatureService
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
}
