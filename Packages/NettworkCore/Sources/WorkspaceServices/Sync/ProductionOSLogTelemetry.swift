import CloudSync
import Foundation
import OSLog

/// Ephemeral OSLog output plus a separately bounded metrics sink. OSLog owns
/// its system retention, so it is never treated as the durable metrics record.
/// It intentionally interpolates no customer-controlled values into OSLog.
public final class ProductionOSLogSyncTelemetry: PrivacySafeSyncTelemetryEmitting, PrivacySafeSyncOperationSignposting, @unchecked Sendable {
    private let logger: Logger
    private let signposter: OSSignposter
    private let retention: SyncTelemetryRetentionPolicy
    private let metrics: any PrivacySafeSyncTelemetryMetricsStoring

    public init(
        subsystem: String,
        retention: SyncTelemetryRetentionPolicy,
        metrics: (any PrivacySafeSyncTelemetryMetricsStoring)? = nil
    ) {
        self.logger = Logger(subsystem: subsystem, category: "sync.reliability")
        self.signposter = OSSignposter(subsystem: subsystem, category: "sync.reliability")
        self.retention = retention
        self.metrics = metrics ?? BoundedPrivacySafeSyncTelemetryStore(retention: retention)
    }

    public func emit(_ event: PrivacySafeSyncTelemetryEvent, retention: SyncTelemetryRetentionPolicy) {
        guard retention == self.retention else {
            logger.error("sync telemetry rejected due to retention policy mismatch")
            return
        }
        metrics.record(event, retention: retention)
        let externalQuotaDescription: String
        switch event.externalQuota {
        case .unavailable:
            externalQuotaDescription = "unavailable"
        case let .reported(usedBytes, limitBytes):
            externalQuotaDescription = "reported usedBytes=\(usedBytes) limitBytes=\(limitBytes)"
        }
        let externalBackupAgeDescription: String
        switch event.externalBackupAge {
        case .unavailable:
            externalBackupAgeDescription = "unavailable"
        case let .reported(ageSeconds):
            externalBackupAgeDescription = "reported ageSeconds=\(ageSeconds)"
        }
        let message = [
            "sync telemetry",
            "operation=\(event.operation.rawValue)",
            "outcome=\(event.outcome.rawValue)",
            "records=\(event.recordCount)",
            "assets=\(event.assetCount)",
            "queue=\(event.queueDepth)",
            "queueAgeSeconds=\(event.oldestQueuedAgeSeconds.map(String.init) ?? "unavailable")",
            "quarantine=\(event.quarantineCount.map(String.init) ?? "unavailable")",
            "conflicts=\(event.conflictCount.map(String.init) ?? "unavailable")",
            "quotaFailures=\(event.quotaExceededFailureCount.map(String.init) ?? "unavailable")",
            "contactAgeSeconds=\(event.lastSuccessfulServerContactAgeSeconds.map(String.init) ?? "unavailable")",
            "externalQuota=\(externalQuotaDescription)",
            "externalBackupAge=\(externalBackupAgeDescription)",
            "failure=\(event.failureCategory?.rawValue ?? "none")",
        ].joined(separator: " ")
        logger.info("\(message, privacy: .public)")
        signposter.emitEvent("syncTelemetry")
    }

    public func beginForegroundSynchronizeOperation() -> PrivacySafeSyncOperationSignpost {
        let signpostID = signposter.makeSignpostID()
        let intervalState = signposter.beginInterval("foregroundSynchronize", id: signpostID)
        return PrivacySafeSyncOperationSignpost(signpostID: signpostID, intervalState: intervalState)
    }

    public func endForegroundSynchronizeOperation(_ operation: PrivacySafeSyncOperationSignpost) {
        guard operation.signpostID != nil, let intervalState = operation.intervalState else {
            return
        }
        signposter.endInterval("foregroundSynchronize", intervalState)
    }
}
