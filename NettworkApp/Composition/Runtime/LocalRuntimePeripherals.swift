import Foundation
import NetworkModel
import OSLog
import WorkspaceChangeControl
import WorkspaceServices

/// Writes aggregate operation measurements to the unified log only. The
/// measurement carries no account, workspace, record or payload identity.
struct LocalRuntimeOperationMeasurementLog: PrivacySafeOperationMeasurementRecording {
    let subsystem: String

    func record(_ measurement: PrivacySafeOperationMeasurement) async {
        Logger(subsystem: subsystem, category: "operation.measurement").debug(
            """
            \(measurement.operation.rawValue, privacy: .public) \(measurement.outcome.rawValue, privacy: .public) \
            \(measurement.durationMilliseconds, privacy: .public)ms in=\(measurement.inputRecordCount, privacy: .public) \
            out=\(measurement.outputRecordCount, privacy: .public) budget=\(String(describing: measurement.budgetEvaluation), privacy: .public)
            """)
    }
}

/// The local runtime has no operator-facing resolution workflow; corrective
/// drafts fail closed instead of guessing a resolution.
struct LocalRuntimeCorrectiveResolutionUnavailable: CorrectiveResolutionProviding {
    func resolution(for _: ReconciliationCase, actorID _: String, in _: PersistenceNamespace) async throws -> CorrectiveResolution {
        throw LocalRuntimeProviderError.correctiveResolutionUnavailable
    }
}

/// Publishes each audit export to a new, never-existing file below the local
/// runtime's `exports/audit/` directory. The exporter itself refuses to
/// overwrite; this provider never names an existing file in the first place.
struct LocalRuntimeAuditExportDestination: ProductionAuditExportDestinationProviding {
    let directory: URL
    let namespace: PersistenceNamespace

    func destination(for operationID: ObjectID, namespace requested: PersistenceNamespace) async throws -> URL {
        guard requested == namespace else { throw LocalRuntimeProviderError.auditDestinationUnavailable }
        try LocalRuntimeLayout.preparePrivateDirectory(directory)
        let name = "audit-\(operationID.description)-\(UUID().uuidString.lowercased()).json"
        let url = directory.appendingPathComponent(name, isDirectory: false)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw LocalRuntimeProviderError.auditDestinationUnavailable }
        return url
    }
}
