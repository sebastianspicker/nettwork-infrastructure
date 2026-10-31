import CloudSync
import CryptoKit
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import WorkspaceServices

/// Conservative stage-1 policy profile of the local runtime. The limits stay
/// within the local record store's 64 MiB snapshot cap; operation budgets are
/// observed signals only and never fail a committed operation.
enum LocalRuntimePolicies {
    static let policyVersion = "nettwork-local-alpha-1"
    static let workspaceName = "Local Workspace"
    /// One fixed generation: a local identity has no account switch, and the
    /// mirror namespace key (which includes the generation) survives relaunches.
    static let sessionGeneration: UInt64 = 1
    static let attachmentStagingLifetime: TimeInterval = 15 * 60
    static let workOrderReservationLifetime: TimeInterval = 15 * 60
    static let cancellationReleaseLifetime: TimeInterval = 5 * 60
    static let telemetryRetention = SyncTelemetryRetentionPolicy(maximumEventAgeSeconds: 86_400, maximumEventCount: 100)
    static let maximumRecordNameIdentities = LocalCloudRecordNameIdentityIndexLimits.minimumCapacity
    static let floorPlanWorkOrderMetadata = FloorPlanWorkOrderMetadata(title: "Floor plan update", ticket: "LOCAL-ALPHA")

    static var telemetrySubsystem: String { (Bundle.main.bundleIdentifier ?? "Nettwork") + ".local-runtime" }

    static var operationPolicies: [BoundedOperationPolicy] {
        BoundedOperationKind.allCases.map { BoundedOperationPolicy(operation: $0, maximumConcurrentOperations: 4, cancellationCheckInterval: 1) }
    }

    static var operationBudgets: [OperationPerformanceBudget] {
        BoundedOperationKind.allCases.map { OperationPerformanceBudget(operation: $0, maximumWallClockMilliseconds: 600_000) }
    }

    static func stagedAssetQuota() throws -> CloudStagedAssetQuotaPolicy {
        try CloudStagedAssetQuotaPolicy(
            maximumAssetsPerTransfer: 16, maximumBytesPerTransfer: 16 * 1_024 * 1_024, maximumBytesPerNamespace: 64 * 1_024 * 1_024)
    }

    static func workOrderPolicy() throws -> ProductionWorkOrderPolicy {
        try ProductionWorkOrderPolicy(policyVersion: policyVersion, reservationLifetime: workOrderReservationLifetime)
    }

    static func attachmentPolicy() throws -> ProductionAttachmentEvidencePolicy {
        try ProductionAttachmentEvidencePolicy(
            quota: AttachmentEvidenceQuotaPolicy(maximumAttachmentCount: 16, maximumTotalBytes: 16 * 1_024 * 1_024, reservationLifetime: 600),
            policyVersion: policyVersion)
    }

    /// Stage 1 has no floor selection; the floor-plan scope is a stable ID
    /// derived from the workspace so staged anchors survive relaunches.
    static func floorID(for workspaceID: ObjectID) -> ObjectID {
        var bytes = Array(SHA256.hash(data: Data("nettwork.local-runtime.floor.v1\0\(workspaceID.description)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // name-based UUID version
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        return ObjectID(UUID(uuid: bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }))
    }
}
