#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    extension CloudKitRecordTransport {
        /// An atomic modify reports the failing record's own error inside `.partialFailure`; the siblings only say `.batchRequestFailed`.
        /// Deterministic choice among item errors: a conflict first, then a possibly-committed
        /// network error, then any other failure.
        static func primaryError(_ error: Error) -> Error {
            guard let cloudError = error as? CKError, cloudError.code == .partialFailure,
                let itemErrors = cloudError.partialErrorsByItemID?.values.filter({ ($0 as? CKError)?.code != .batchRequestFailed }),
                !itemErrors.isEmpty
            else { return error }
            return itemErrors.first(where: isServerRecordChanged) ?? itemErrors.first(where: isIndeterminateNetworkError)
                ?? itemErrors.min { String(describing: $0) < String(describing: $1) } ?? error
        }

        static func isServerRecordChanged(_ error: Error) -> Bool {
            (error as? CKError)?.code == .serverRecordChanged
        }

        /// The save may have committed before the failure, so the caller must check the receipt before retrying.
        static func isIndeterminateNetworkError(_ error: Error) -> Bool {
            guard let cloudError = error as? CKError else { return false }
            switch cloudError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .serverResponseLost, .zoneBusy: return true
            default: return false
            }
        }

        static func failure(for error: Error, resourceKeys: Set<ResourceKey>) -> SyncFailure {
            guard let cloudError = error as? CKError else {
                return SyncFailure(category: .unknown, message: String(describing: error), resourceKeys: resourceKeys)
            }
            switch cloudError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable, .serverResponseLost, .zoneBusy:
                return SyncFailure(category: .network, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            case .requestRateLimited:
                return SyncFailure(
                    category: .rateLimited, message: cloudError.localizedDescription,
                    retryAfter: cloudError.retryAfterSeconds.map { Date.now.addingTimeInterval($0) }, resourceKeys: resourceKeys)
            case .quotaExceeded: return SyncFailure(category: .quotaExceeded, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            case .notAuthenticated: return SyncFailure(category: .accountUnavailable, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            case .permissionFailure: return SyncFailure(category: .permissionDenied, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            case .serverRecordChanged: return SyncFailure(category: .conflict, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            default: return SyncFailure(category: .unknown, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            }
        }
    }
#endif
