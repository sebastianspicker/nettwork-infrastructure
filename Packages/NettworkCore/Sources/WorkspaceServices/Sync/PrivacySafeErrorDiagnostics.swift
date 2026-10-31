import CloudSync
import Foundation
import WorkspaceChangeControl

/// Bug-report diagnostics that never carry customer-controlled values: an
/// error is described by its type and enum case name (associated values are
/// dropped) or, for other errors, by its Foundation domain and code.
public enum PrivacySafeErrorDiagnostics {
    public static func label(for error: Error) -> String {
        let typeName = String(reflecting: type(of: error))
        let mirror = Mirror(reflecting: error)
        if mirror.displayStyle == .enum {
            // A payload case is named by its label; a payload-free case
            // describes itself by name (no error type customises its description).
            let caseName = mirror.children.first?.label ?? String(describing: error)
            return "\(typeName).\(caseName)"
        }
        let nsError = error as NSError
        return "\(typeName) \(nsError.domain)#\(nsError.code)"
    }

    public static func telemetryFailureCategory(for error: Error) -> PrivacySafeSyncTelemetryFailureCategory {
        PrivacySafeSyncTelemetryFailureCategory(CloudFailureClassifier.classify(error))
    }
}

extension PrivacySafeSyncTelemetryFailureCategory {
    public init(_ failure: SyncFailure) {
        switch failure.category {
        case .network, .rateLimited, .quotaExceeded, .accountUnavailable, .permissionDenied:
            self = Self.transportCategory(failure.category)
        case .validation, .conflict, .malformedRemoteRecord, .security, .unknown:
            self = Self.dataCategory(failure.category)
        }
    }

    private static func transportCategory(_ category: SyncFailureCategory) -> Self {
        switch category {
        case .network: .networkFlap
        case .rateLimited: .rateLimited
        case .quotaExceeded: .quotaExceeded
        case .accountUnavailable: .accountUnavailable
        default: .permissionDenied
        }
    }

    private static func dataCategory(_ category: SyncFailureCategory) -> Self {
        switch category {
        case .validation: .validation
        case .conflict: .conflict
        case .malformedRemoteRecord: .malformedRemoteRecord
        case .security: .security
        default: .unknown
        }
    }
}
