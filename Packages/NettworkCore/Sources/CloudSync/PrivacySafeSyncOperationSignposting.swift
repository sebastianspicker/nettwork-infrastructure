import Foundation
import OSLog

/// A short-lived handle for one bounded foreground synchronization interval.
/// It carries OSLog's interval state only; it cannot carry customer data.
public struct PrivacySafeSyncOperationSignpost: @unchecked Sendable {
    public let signpostID: OSSignpostID?
    public let intervalState: OSSignpostIntervalState?

    public init(signpostID: OSSignpostID? = nil, intervalState: OSSignpostIntervalState? = nil) {
        self.signpostID = signpostID
        self.intervalState = intervalState
    }
}

/// Keeps operation timing separate from aggregate telemetry emission so the
/// signpost measures the synchronization work instead of log formatting.
public protocol PrivacySafeSyncOperationSignposting: Sendable {
    func beginForegroundSynchronizeOperation() -> PrivacySafeSyncOperationSignpost
    func endForegroundSynchronizeOperation(_ operation: PrivacySafeSyncOperationSignpost)
}
