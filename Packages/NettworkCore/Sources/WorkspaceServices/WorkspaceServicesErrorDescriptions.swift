import Foundation

extension ProductionSessionAuthorizationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .noVerifiedSession, .sessionSuperseded, .invalidSessionID:
            "Your session is no longer valid. Sign in again and retry."
        case .namespaceMismatch, .presentationMismatch:
            "The request was not authorized for this workspace. Sync and try again."
        }
    }
}

extension ProductionFeatureMutationAuthorityError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPolicy, .namespaceMismatch, .workspaceInactive:
            "The request was not authorized for this workspace. Sync and try again."
        case .invalidDraft, .unsupportedDraft:
            "The work order draft is not valid. Review the draft and try again."
        case .workOrderMissing, .malformedWorkOrder:
            "The work order could not be found or read. Sync and try again."
        case .invalidReservation, .reservationNotAcknowledged, .materialOutsideReservation:
            "The resources for this work order are not reserved correctly. Reserve them again."
        case .invalidCancellationRequestState, .cancellationNotRequested, .invalidCancellationReleaseAuthorization:
            "The work order cannot be cancelled in its current state. Review its status."
        case .receiptMismatch:
            "The change could not be confirmed. Sync and try again."
        case .missingMaterialPrecondition, .malformedMaterialPrecondition:
            "The work order data is incomplete. Sync and try again."
        }
    }
}

extension ProductionCorrectiveDraftBuilderError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .namespaceMismatch:
            "The conflict belongs to a different workspace. Open that workspace and try again."
        case .reconciliationCaseMissing:
            "The conflict could not be found. It may already be resolved. Sync and check again."
        case .securityCase:
            "This conflict needs an administrator to resolve it."
        case .staleResolution, .invalidResolution:
            "The conflict changed while you were resolving it. Reload it and try again."
        }
    }
}

extension ProductionMirrorDomainNormalizationError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .ambiguousAggregate, .incompletePlacementProjection, .malformedRecord, .resourceKeyMismatch:
            "The synced copy of your workspace is inconsistent. Sync again."
        }
    }
}

extension SwiftDataCloudRecordNameIdentityIndexError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .namespaceMismatch, .invalidMaximumEntries, .capacityConfigurationMismatch:
            "The sync index does not match this workspace. Restart the app and sync again."
        }
    }
}

extension SwiftDataCloudKitSyncEngineStateStoreError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .namespaceMismatch, .unappliedState:
            "The sync state does not match this workspace. Sync again."
        }
    }
}

extension FileBackedWorkOrderDraftStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let version):
            "The saved work-order drafts use unsupported format version \(version). Update the app to open them."
        case .corruptDraftFile, .namespaceMismatch:
            "The saved work-order drafts are damaged and were not loaded. They were left on disk unchanged."
        case .draftFileTooLarge(let byteCount):
            "The saved work-order drafts (\(byteCount) bytes) exceed the size limit."
        case .readFailed(let reason):
            "The saved work-order drafts could not be read: \(reason)"
        case .writeFailed(let reason):
            "The work-order draft could not be saved: \(reason)"
        }
    }
}
