import ContentSafety
import Foundation
import OSLog

extension ProductionRuntimeAssembly {
    /// Removes staging that an earlier app kill left behind. Only marked,
    /// expired items below the three roots are selected (see `StagingSweep`);
    /// archive restore operation directories hold a durable retry sidecar and
    /// are never swept. Failures are logged and never block launch.
    /// The first sweep of this process; later assemblies (account switches) only
    /// remove staging that already existed then, never this process's own work.
    private static let stagingSweepEpoch = Date()

    static func sweepStaleStaging(_ input: OrganizationInput, now: Date = Date()) {
        let storage = input.workspaceStorage
        let lifetime = storage.attachmentStagingLifetime
        let now = min(now, stagingSweepEpoch.addingTimeInterval(lifetime))
        let roots: [(URL, StagingSweep.Layout)] = [
            (storage.attachmentStagingDirectory, .filesInNamespaceDirectories),
            (storage.archiveRestoreStagingDirectory.appendingPathComponent(".verification", isDirectory: true), .unitDirectories),
            // Prepared-but-unpublished audit exports; same lifetime as attachment staging.
            (storage.auditPrivateDirectory, .unitDirectories),
        ]
        let logger = Logger(subsystem: input.cloudWorkspace.telemetrySubsystem, category: "staging.sweep")
        for (root, layout) in roots {
            let failures = StagingSweep.sweep(
                root: root, layout: layout, now: now, lifetime: lifetime,
                remove: { try FileManager.default.removeItem(at: $0) })
            for failure in failures {
                logger.error("Staging sweep could not remove an expired item: \(String(describing: failure), privacy: .public)")
            }
        }
    }
}
