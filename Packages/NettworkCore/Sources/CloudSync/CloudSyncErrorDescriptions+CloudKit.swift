#if canImport(CloudKit)
    import Foundation

    extension CloudKitSyncEngineBatchSourceError: LocalizedError {
        public var errorDescription: String? {
            switch self {
            case .invalidIdentityIndexLimit, .invalidBatchAdmissionLimit, .batchAdmissionLimitExceeded:
                "The cloud sync is too large to process at once. Sync again later."
            case .bindingMismatch, .persistedStateMismatch, .invalidStateSerialization, .missingPostFetchState:
                "The saved sync state does not match this workspace. Sync again."
            case .fetchedStateAwaitingMirrorCommit, .overlappingFetch, .fetchFinishedWithoutDelegateCompletion:
                "Another sync is still running. Wait for it to finish and try again."
            case .accountChanged, .workspaceZoneDeleted:
                "The iCloud account or workspace changed. Open the workspace again and sync."
            case .recordZoneFetchFailed, .unexpectedZone, .unknownEvent:
                "Syncing with iCloud failed. Check your connection and try again."
            case .invalidRemoteIdentity, .duplicateRecordName, .identityIndexFailure, .invalidRemoteAsset:
                "The cloud returned data that could not be used. Sync again."
            }
        }
    }

    extension CloudKitSyncEngineStateError: LocalizedError {
        public var errorDescription: String? {
            switch self {
            case .fetchedStateAwaitingMirrorCommit, .appliedStateDoesNotMatchFetchedState:
                "The sync state is out of date. Sync again."
            }
        }
    }

    extension CloudKitAdapterError: LocalizedError {
        public var errorDescription: String? {
            switch self {
            case .conditionalWriteFailed:
                "The cloud has newer changes than yours, so your change was not saved. Sync and try again."
            case .invalidSystemFields, .receiptPayloadMissing, .invalidRecordAsset:
                "The cloud response could not be used. Sync and try again."
            }
        }
    }
#endif
