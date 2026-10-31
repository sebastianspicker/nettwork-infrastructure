import Foundation

extension CloudWorkspaceAssetRecordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidIdentity, .invalidPath, .invalidMetadata:
            "A synced file has invalid details and was not used. Sync again."
        }
    }
}

extension RemoteRecordValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownRecordType, .unsupportedSchema:
            "The cloud contains data from a newer version of the app. Update the app and sync again."
        case .recordOutsideWorkspace, .invalidRecordName, .nonDeterministicRecordName, .duplicateResource:
            "The cloud returned data that does not belong to this workspace. Sync again."
        case .payloadTooLarge, .systemFieldsTooLarge, .emptyPayload:
            "A synced item has an unexpected size and was skipped. Sync again."
        case .missingChangeTag, .tombstoneNotAllowed, .invalidVisibility:
            "The cloud returned an incomplete item. Sync again."
        case .invalidRecordAsset:
            "A synced file is invalid and was not used. Sync again."
        }
    }
}

extension CloudActivationMutationEncodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateRecord, .invalidRecordType, .invalidRecordName:
            "The import data could not be prepared for the cloud. Start the import again."
        case .missingCloudPrecondition:
            "The workspace state in the cloud is unknown. Sync and start the import again."
        }
    }
}

extension CloudMutationEncodingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .duplicateRecord, .invalidRecordType, .invalidRecordName:
            "Your change could not be prepared for the cloud. Review it and try again."
        case .missingCloudPrecondition, .invalidReadAssertion:
            "The workspace state in the cloud is unknown. Sync and try again."
        }
    }
}

extension AtomicCloudMutationValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .recordOutsideWorkspace, .nondeterministicRecordName, .duplicateResource, .invalidRecordAsset:
            "Your change contains data that does not belong to this workspace. Review the change and try again."
        case .assertionPreservationRequiresExactPrecondition, .preconditionSetMismatch, .invalidExactPrecondition:
            "Your change could not be checked against the cloud data. Sync and try again."
        case .stagedBatchTooLarge, .atomicBatchTooLarge:
            "Your change is too large to sync at once. Split it into smaller changes."
        }
    }
}

extension CloudExactMutationStateError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .workspaceMismatch:
            "The change belongs to a different workspace. Open that workspace and try again."
        case .mutationTooLarge:
            "Your change is too large to sync at once. Split it into smaller changes."
        case .malformedWorkOrderRecord, .malformedReadAssertionRecord, .returnedSnapshotMismatch:
            "The cloud data for this change is incomplete. Sync and try again."
        }
    }
}

extension AuthoritativeActivationMutationStateProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupported:
            "This kind of change is not supported on this device."
        }
    }
}

extension CloudRecordNameIdentityIndexError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidMaximumEntries, .invalidIdentity:
            "The sync index could not be used. Restart the app and sync again."
        }
    }
}

extension CloudMirrorAdapterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .namespaceNotOpen:
            "The workspace is not open. Open the workspace and sync again."
        case .unsupportedSemanticRecord:
            "The cloud contains data from a newer version of the app. Update the app and sync again."
        case .malformedPayload:
            "A synced item is damaged and was skipped. Sync again."
        }
    }
}

extension CloudRemoteReferenceValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRecords:
            "Some synced items refer to data that is missing. Sync again."
        }
    }
}

extension CloudStagedTransferGCError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPolicy, .malformedCandidate, .staleCandidate, .invalidMember, .pageLimitExceeded:
            "Cleaning up temporary transfer files failed. Restart the app and try again."
        case .protectedTransfer:
            "The transfer is still in use and was kept. Try again later."
        }
    }
}

extension CloudStagedTransferError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidSession, .invalidMember, .invalidBatchSize, .cursorConflict:
            "The transfer could not continue. Start the transfer again."
        case .incompleteTransfer, .protectedAssetMissing:
            "Some of the transferred data is missing. Start the transfer again."
        case .digestMismatch:
            "The transferred data changed unexpectedly. Start the transfer again."
        case .lifecycleConflict:
            "The transfer was changed by another action. Start the transfer again."
        }
    }
}
