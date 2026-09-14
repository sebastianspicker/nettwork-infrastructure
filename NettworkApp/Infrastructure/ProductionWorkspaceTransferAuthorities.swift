import CloudSync
import Foundation
import ImportExport
import NetworkModel
import Persistence
import WorkspaceChangeControl

enum ProductionWorkspaceTransferAuthorityError: Error, Equatable, Sendable {
    case namespaceMismatch, bootstrapSentinelMissing, malformedBootstrapSentinel, workspaceNotEmpty
    case malformedMirrorRecord(ResourceKey)
    case unsupportedMirrorTombstone(ResourceKey)
    case nonCanonicalTransfer
    case malformedArchiveAudit
    case duplicateActivationResource(ResourceKey)
    case archiveSourceMismatch, archiveRootMismatch
    case receiptMismatch, malformedStagedTransfer, missingArchiveAsset, invalidArchiveAsset, malformedArchiveOperationalState
    case legacyAggregateRequiresMigration
}

struct ProductionArchiveAsset: Sendable {
    enum Owner: Sendable {
        case workspaceAsset
        case attachmentEvidence(AttachmentEvidenceBindingRecord)
        case floorPlan(FloorPlanAssetBindingRecord)
    }

    let assetID: ObjectID
    let stableID: String
    let relativePath: String
    let contentType: String
    let bytes: Data
    let owner: Owner
}

protocol ProductionArchiveAssetSource: Sendable {
    func assets(in namespace: PersistenceNamespace) async throws -> [ProductionArchiveAsset]
}

/// The final authority mutation changes only the workspace sentinel. Every
/// imported member is a separate invisible staged Cloud record.
actor ProductionWorkspaceTransferAuthority: CSVImportActivationAuthority, ArchiveExportSource, FileBackedArchiveRestoreActivationAuthority {
    static let activationPolicyVersion = "workspace-transfer-activation-v2"
    static let workspaceAssetFieldName = "workspaceAsset"
    static let attachmentEvidenceAssetsDirectory = ArchiveLayout.assetsDirectory + "/attachment-evidence"
    static let floorPlanAssetsDirectory = ArchiveLayout.assetsDirectory + "/floor-plans"
    let account: AccountContext
    let persistence: SwiftDataPersistenceStore
    let sessionAuthorizer: ProductionSessionAuthorizer
    let exactRecords: any CloudExactRecordReading
    let stagedTransfers: CloudStagedTransferRepository
    let mutations: any AuthoritativeMutationRepository
    let assetSource: any ProductionArchiveAssetSource

    init(
        account: AccountContext, persistence: SwiftDataPersistenceStore, sessionAuthorizer: ProductionSessionAuthorizer,
        exactRecords: any CloudExactRecordReading, stagedTransfers: CloudStagedTransferRepository, mutations: any AuthoritativeMutationRepository,
        assetSource: any ProductionArchiveAssetSource
    ) {
        self.account = account
        self.persistence = persistence
        self.sessionAuthorizer = sessionAuthorizer
        self.exactRecords = exactRecords
        self.stagedTransfers = stagedTransfers
        self.mutations = mutations
        self.assetSource = assetSource
    }
}
