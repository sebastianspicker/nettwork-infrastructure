import CloudKit
import CloudSync
import ContentSafety
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Persistence
import SwiftData
import WorkspaceChangeControl
import WorkspaceServices

/// Every capability the runtime needs from a record backend. The CloudKit
/// transport and the local transport both satisfy it.
typealias ProductionRuntimeRecordTransport =
    CloudRecordTransport & CloudConditionalBatchTransport & CloudReceiptLookupTransport & CloudExactRecordReading & CloudAppliedChangeStatePersisting

extension ProductionRuntimeAssembly {
    struct OrganizationInput {
        struct WorkspaceStorage {
            let modelContainer: ModelContainer
            let attachmentDirectory: URL
            let attachmentStagingDirectory: URL
            let csvStagingDirectory: URL
            let archiveRestoreStagingDirectory: URL
            let auditPrivateDirectory: URL
            /// Private, per-workspace directory of the durable Favorites and Recents.
            let historyDirectory: URL
            let attachmentStagingLifetime: TimeInterval
            let attachmentStagingProtection: any AttachmentStagingFileProtection
            let stagedWorkOrderDraftStore: any ProductionStagedWorkOrderDraftStoring

            init(
                modelContainer: ModelContainer,
                attachmentDirectory: URL,
                attachmentStagingDirectory: URL,
                csvStagingDirectory: URL,
                archiveRestoreStagingDirectory: URL,
                auditPrivateDirectory: URL,
                historyDirectory: URL,
                attachmentStagingLifetime: TimeInterval,
                attachmentStagingProtection: any AttachmentStagingFileProtection,
                stagedWorkOrderDraftStore: any ProductionStagedWorkOrderDraftStoring
            ) {
                self.modelContainer = modelContainer
                self.attachmentDirectory = attachmentDirectory
                self.attachmentStagingDirectory = attachmentStagingDirectory
                self.csvStagingDirectory = csvStagingDirectory
                self.archiveRestoreStagingDirectory = archiveRestoreStagingDirectory
                self.auditPrivateDirectory = auditPrivateDirectory
                self.historyDirectory = historyDirectory
                self.attachmentStagingLifetime = attachmentStagingLifetime
                self.attachmentStagingProtection = attachmentStagingProtection
                self.stagedWorkOrderDraftStore = stagedWorkOrderDraftStore
            }
        }

        struct CloudWorkspace {
            /// CloudKit-specific collaborators; consumed only by the CloudKit
            /// branch of the composition root.
            struct CloudKitBackend {
                let cloudKitContainer: CKContainer
                let cloudKitSubscriptionID: CKSubscription.ID?
                let workspaceContextStore: any CloudKitWorkspaceContextStore
                let workspaceShareService: any CloudKitWorkspaceShareService
                let workspaceBootstrapper: any CloudKitWorkspaceBootstrapper
            }

            /// Protocol-typed local backend. It supplies the single record
            /// transport and the workspace authority; no CloudKit type is involved.
            /// The transport is built per assembly over that assembly's sync-state
            /// store, whose reads need the foundation persistence's namespace lease.
            /// The assembly awaits it before any sync runs.
            struct LocalBackend {
                let makeTransport: (any CloudKitSyncEngineStateStore) async throws -> any ProductionRuntimeRecordTransport
                let workspaceAuthority: any CloudWorkspaceAuthority
            }

            enum Backend {
                case cloudKit(CloudKitBackend)
                case local(LocalBackend)

                var kind: BackendKind {
                    switch self {
                    case .cloudKit: .cloudKit
                    case .local: .local
                    }
                }
            }

            /// Payload-free backend discriminator used by wiring validation.
            enum BackendKind {
                case cloudKit
                case local
            }

            let account: AccountContext
            let workspaceName: String
            let backend: Backend
            let maximumRecordNameIdentities: Int
            let stagedAssetQuota: CloudStagedAssetQuotaPolicy
            /// Nil means the organization has not approved staged-transfer GC.
            let stagedTransferGCPolicy: CloudStagedTransferGCPolicy?
            let telemetrySubsystem: String
            let telemetryRetention: SyncTelemetryRetentionPolicy
            let telemetryExternalSignalProvider: any PrivacySafeSyncTelemetryExternalSignalProviding
            let telemetryMetricsStore: any PrivacySafeSyncTelemetryMetricsStoring
            let actorContextProvider: any CloudForegroundActorContextProvider
            let installationSession: any ProductionInstallationSessionProviding
            let remoteRecordValidator: CloudRemoteRecordValidator

            /// Source-compatible initialiser for the CloudKit backend.
            init(
                account: AccountContext,
                workspaceName: String,
                cloudKitContainer: CKContainer,
                cloudKitSubscriptionID: CKSubscription.ID?,
                maximumRecordNameIdentities: Int,
                stagedAssetQuota: CloudStagedAssetQuotaPolicy,
                stagedTransferGCPolicy: CloudStagedTransferGCPolicy?,
                telemetrySubsystem: String,
                telemetryRetention: SyncTelemetryRetentionPolicy,
                telemetryExternalSignalProvider: any PrivacySafeSyncTelemetryExternalSignalProviding,
                telemetryMetricsStore: any PrivacySafeSyncTelemetryMetricsStoring,
                workspaceContextStore: any CloudKitWorkspaceContextStore,
                workspaceShareService: any CloudKitWorkspaceShareService,
                workspaceBootstrapper: any CloudKitWorkspaceBootstrapper,
                actorContextProvider: any CloudForegroundActorContextProvider,
                installationSession: any ProductionInstallationSessionProviding,
                remoteRecordValidator: CloudRemoteRecordValidator
            ) {
                self.init(
                    account: account,
                    workspaceName: workspaceName,
                    backend: .cloudKit(
                        CloudKitBackend(
                            cloudKitContainer: cloudKitContainer,
                            cloudKitSubscriptionID: cloudKitSubscriptionID,
                            workspaceContextStore: workspaceContextStore,
                            workspaceShareService: workspaceShareService,
                            workspaceBootstrapper: workspaceBootstrapper
                        )),
                    maximumRecordNameIdentities: maximumRecordNameIdentities,
                    stagedAssetQuota: stagedAssetQuota,
                    stagedTransferGCPolicy: stagedTransferGCPolicy,
                    telemetrySubsystem: telemetrySubsystem,
                    telemetryRetention: telemetryRetention,
                    telemetryExternalSignalProvider: telemetryExternalSignalProvider,
                    telemetryMetricsStore: telemetryMetricsStore,
                    actorContextProvider: actorContextProvider,
                    installationSession: installationSession,
                    remoteRecordValidator: remoteRecordValidator
                )
            }

            init(
                account: AccountContext,
                workspaceName: String,
                backend: Backend,
                maximumRecordNameIdentities: Int,
                stagedAssetQuota: CloudStagedAssetQuotaPolicy,
                stagedTransferGCPolicy: CloudStagedTransferGCPolicy?,
                telemetrySubsystem: String,
                telemetryRetention: SyncTelemetryRetentionPolicy,
                telemetryExternalSignalProvider: any PrivacySafeSyncTelemetryExternalSignalProviding,
                telemetryMetricsStore: any PrivacySafeSyncTelemetryMetricsStoring,
                actorContextProvider: any CloudForegroundActorContextProvider,
                installationSession: any ProductionInstallationSessionProviding,
                remoteRecordValidator: CloudRemoteRecordValidator
            ) {
                self.account = account
                self.workspaceName = workspaceName
                self.backend = backend
                self.maximumRecordNameIdentities = maximumRecordNameIdentities
                self.stagedAssetQuota = stagedAssetQuota
                self.stagedTransferGCPolicy = stagedTransferGCPolicy
                self.telemetrySubsystem = telemetrySubsystem
                self.telemetryRetention = telemetryRetention
                self.telemetryExternalSignalProvider = telemetryExternalSignalProvider
                self.telemetryMetricsStore = telemetryMetricsStore
                self.actorContextProvider = actorContextProvider
                self.installationSession = installationSession
                self.remoteRecordValidator = remoteRecordValidator
            }
        }

        struct OperationGovernance {
            let operationPolicies: [BoundedOperationPolicy]
            let operationPerformanceBudgets: [OperationPerformanceBudget]
            let operationMeasurementSink: any PrivacySafeOperationMeasurementRecording
            let workOrderPolicy: ProductionWorkOrderPolicy
            let attachmentPolicy: ProductionAttachmentEvidencePolicy
            let correctiveResolutionProvider: any CorrectiveResolutionProviding
            let auditDestination: any ProductionAuditExportDestinationProviding
            let archiveVerifier: ArchiveVerifier
            let floorPlanWorkOrderMetadata: FloorPlanWorkOrderMetadata

            init(
                operationPolicies: [BoundedOperationPolicy],
                operationPerformanceBudgets: [OperationPerformanceBudget],
                operationMeasurementSink: any PrivacySafeOperationMeasurementRecording,
                workOrderPolicy: ProductionWorkOrderPolicy,
                attachmentPolicy: ProductionAttachmentEvidencePolicy,
                correctiveResolutionProvider: any CorrectiveResolutionProviding,
                auditDestination: any ProductionAuditExportDestinationProviding,
                archiveVerifier: ArchiveVerifier,
                floorPlanWorkOrderMetadata: FloorPlanWorkOrderMetadata
            ) {
                self.operationPolicies = operationPolicies
                self.operationPerformanceBudgets = operationPerformanceBudgets
                self.operationMeasurementSink = operationMeasurementSink
                self.workOrderPolicy = workOrderPolicy
                self.attachmentPolicy = attachmentPolicy
                self.correctiveResolutionProvider = correctiveResolutionProvider
                self.auditDestination = auditDestination
                self.archiveVerifier = archiveVerifier
                self.floorPlanWorkOrderMetadata = floorPlanWorkOrderMetadata
            }
        }

        struct FeatureContext {
            let floorID: ObjectID
            let floorPlanAnchors: [FloorPlanAnchor]
            let floorPlanLabels: [ObjectID: String]
            let templatePolicy: TemplateAdministrationPolicy
            let operationsAuthorization: OperationsAuthorization
            let cancellationReleaseAuthorization: (CancellationReleaseRequest) -> CancellationReleaseAuthorization?
            let auditExportAuthorization: () -> AuthorizedOperationContext?
            let floorPlanImportSource: () -> (any OpaqueContentSource)?
            let attachmentAuthorization: () -> AuthorizedOperationContext?
            let floorPlanPreviewAuthorization: () -> AuthorizedOperationContext?
            let workOrderEvidenceSource: () -> (any OpaqueContentSource)?
            let workOrderEvidenceAuthorization: () -> AuthorizedOperationContext?
            let csvImportDocument: () -> CSVImportDocument?
            let importAuthorization: () -> AuthorizedOperationContext?
            let csvExportAuthorization: () -> AuthorizedOperationContext?
            let csvExportDestination: (any CSVWorkspaceExportDestination)?
            let archiveExportAuthorization: () -> AuthorizedOperationContext?
            let archiveRestoreSource: () -> (any ArchiveEntrySource)?
            let archiveRestoreAuthorization: () -> AuthorizedOperationContext?
            let workspaceShareMetadata: () -> Data?
            let onWorkspaceInvitationPrepared: (WorkspaceInviteReceipt) -> Void
            let acceptedShareActivation: @MainActor (AccountContext) async throws -> Void

            init(
                floorID: ObjectID,
                floorPlanAnchors: [FloorPlanAnchor],
                floorPlanLabels: [ObjectID: String],
                templatePolicy: TemplateAdministrationPolicy,
                operationsAuthorization: OperationsAuthorization,
                cancellationReleaseAuthorization: @escaping (CancellationReleaseRequest) -> CancellationReleaseAuthorization?,
                auditExportAuthorization: @escaping () -> AuthorizedOperationContext?,
                floorPlanImportSource: @escaping () -> (any OpaqueContentSource)?,
                attachmentAuthorization: @escaping () -> AuthorizedOperationContext?,
                floorPlanPreviewAuthorization: @escaping () -> AuthorizedOperationContext?,
                workOrderEvidenceSource: @escaping () -> (any OpaqueContentSource)?,
                workOrderEvidenceAuthorization: @escaping () -> AuthorizedOperationContext?,
                csvImportDocument: @escaping () -> CSVImportDocument?,
                importAuthorization: @escaping () -> AuthorizedOperationContext?,
                csvExportAuthorization: @escaping () -> AuthorizedOperationContext?,
                csvExportDestination: (any CSVWorkspaceExportDestination)?,
                archiveExportAuthorization: @escaping () -> AuthorizedOperationContext?,
                archiveRestoreSource: @escaping () -> (any ArchiveEntrySource)?,
                archiveRestoreAuthorization: @escaping () -> AuthorizedOperationContext?,
                workspaceShareMetadata: @escaping () -> Data?,
                onWorkspaceInvitationPrepared: @escaping (WorkspaceInviteReceipt) -> Void,
                acceptedShareActivation: @escaping @MainActor (AccountContext) async throws -> Void
            ) {
                self.floorID = floorID
                self.floorPlanAnchors = floorPlanAnchors
                self.floorPlanLabels = floorPlanLabels
                self.templatePolicy = templatePolicy
                self.operationsAuthorization = operationsAuthorization
                self.cancellationReleaseAuthorization = cancellationReleaseAuthorization
                self.auditExportAuthorization = auditExportAuthorization
                self.floorPlanImportSource = floorPlanImportSource
                self.attachmentAuthorization = attachmentAuthorization
                self.floorPlanPreviewAuthorization = floorPlanPreviewAuthorization
                self.workOrderEvidenceSource = workOrderEvidenceSource
                self.workOrderEvidenceAuthorization = workOrderEvidenceAuthorization
                self.csvImportDocument = csvImportDocument
                self.importAuthorization = importAuthorization
                self.csvExportAuthorization = csvExportAuthorization
                self.csvExportDestination = csvExportDestination
                self.archiveExportAuthorization = archiveExportAuthorization
                self.archiveRestoreSource = archiveRestoreSource
                self.archiveRestoreAuthorization = archiveRestoreAuthorization
                self.workspaceShareMetadata = workspaceShareMetadata
                self.onWorkspaceInvitationPrepared = onWorkspaceInvitationPrepared
                self.acceptedShareActivation = acceptedShareActivation
            }
        }

        struct PlatformCapabilities {
            let scanCapture: (@escaping @MainActor (ObjectID) -> Void) -> any ScanCapturing
            let labelGenerator: () -> any LabelPDFGenerating
            let labelExporter: () -> any LabelPDFExporting
            let labelPrinter: () -> any LabelPrinting

            init(
                scanCapture: @escaping (@escaping @MainActor (ObjectID) -> Void) -> any ScanCapturing,
                labelGenerator: @escaping () -> any LabelPDFGenerating,
                labelExporter: @escaping () -> any LabelPDFExporting,
                labelPrinter: @escaping () -> any LabelPrinting
            ) {
                self.scanCapture = scanCapture
                self.labelGenerator = labelGenerator
                self.labelExporter = labelExporter
                self.labelPrinter = labelPrinter
            }
        }

        let workspaceStorage: WorkspaceStorage
        let cloudWorkspace: CloudWorkspace
        let operationGovernance: OperationGovernance
        let featureContext: FeatureContext
        /// Optional organization override. Nil selects the scene-owned system
        /// adapters supplied by the application composition root.
        let platformCapabilities: PlatformCapabilities?

        init(
            workspaceStorage: WorkspaceStorage,
            cloudWorkspace: CloudWorkspace,
            operationGovernance: OperationGovernance,
            featureContext: FeatureContext,
            platformCapabilities: PlatformCapabilities?
        ) {
            self.workspaceStorage = workspaceStorage
            self.cloudWorkspace = cloudWorkspace
            self.operationGovernance = operationGovernance
            self.featureContext = featureContext
            self.platformCapabilities = platformCapabilities
        }
    }
}
