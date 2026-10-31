import Foundation
import WorkspaceChangeControl

extension CloudAuthoritativeCommitError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .returnedReceiptMismatch:
            "The cloud response did not match your change, so it was not applied. Sync and try again."
        case .reconciliationRequired:
            "Your change conflicts with newer changes in the cloud. Review the conflict and resolve it."
        case .retryable:
            "Syncing did not finish. Check your connection and try again in a moment."
        case let .permanent(failure):
            failure.category.permanentFailureDescription
        }
    }
}

extension SyncFailureCategory {
    fileprivate var permanentFailureDescription: String {
        switch self {
        case .network, .rateLimited, .unknown:
            "Syncing failed. Check your connection and try again later."
        case .quotaExceeded:
            "Your cloud storage is full. Free up space and sync again."
        case .accountUnavailable:
            "Your iCloud account is unavailable. Sign in to iCloud and try again."
        case .permissionDenied, .security:
            "The request was not authorized for this workspace. Sync and try again."
        case .validation, .malformedRemoteRecord:
            "The cloud rejected the change because its data is not valid. Review the change and try again."
        case .conflict:
            "Your change conflicts with newer changes in the cloud. Sync and try again."
        }
    }
}

extension OfficialClientPolicyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .viewerCannotMutate, .readOnlyShareCannotMutate:
            "You have read-only access to this workspace and cannot change it."
        case .technicianCannotAdminister:
            "Only administrators can make this change. Ask an administrator."
        case .staleActorSession, .accountMismatch:
            "Your session is no longer valid for this workspace. Sign in again and retry."
        }
    }
}

extension CloudSessionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .superseded:
            "Your session was replaced by a newer one. Retry the action."
        }
    }
}

extension CloudReservationAcknowledgementServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .actorSnapshotMismatch:
            "Your permissions changed while the reservation was confirmed. Sync and try again."
        case .reservationRecordMissing:
            "The reservation for this work order could not be found. Reserve the resources again."
        case .workspaceInactive:
            "This workspace is not active. Open an active workspace and try again."
        }
    }
}

extension CloudReservationAcknowledgementError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidAccountScope, .invalidActor:
            "You are not allowed to confirm this reservation. Sync and try again."
        case .missingReservation, .recordMismatch, .intentMismatch:
            "The reservation does not match the work order. Reserve the resources again."
        case .alreadyAcknowledged:
            "This reservation has already been confirmed."
        case .invalidAcknowledgementWindow:
            "The time allowed to confirm the reservation is not valid. Reserve the resources again."
        }
    }
}

extension OfflineEligibilityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .namespaceMismatch, .staleSession, .actorMismatch:
            "This change cannot be made offline with your current session. Connect and sync, then try again."
        case .intentMismatch, .operationResourceSetMismatch, .reservationDoesNotExactlyCoverMutation:
            "This change does not match the reserved work order. Review the work order and try again."
        case .reservationMissing, .reservationNotAcknowledged, .reservationOwnerMismatch:
            "The work order has no confirmed reservation. Connect and sync to reserve the resources."
        case .acknowledgementScopeMismatch, .acknowledgementSessionMismatch, .acknowledgementReservationMismatch,
            .acknowledgementIntentMismatch, .acknowledgementMissingConditionalMetadata:
            "The reservation confirmation is not valid for this change. Connect and sync, then try again."
        case .acknowledgementExpired:
            "The reservation confirmation has expired. Connect and sync to renew it."
        }
    }
}

extension CloudStagedAssetQuotaError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPolicy, .missingTransferSession, .abandonedTransfer, .duplicateAsset:
            "The file transfer could not continue. Start the transfer again."
        case .transferQuotaExceeded, .namespaceQuotaExceeded:
            "The files are larger than the allowed storage. Choose fewer or smaller files."
        }
    }
}

extension CloudKitWorkspaceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .containerMismatch, .invalidContext, .unknownContext:
            "This workspace does not belong to the configured iCloud container or account. Open the workspace again."
        case .contextStoreCorrupt, .contextStoreReadFailed, .contextStoreWriteFailed:
            "The saved workspace list on this device could not be used. Contact your administrator."
        case .invalidInvitation, .invitationRejected:
            "This workspace invitation cannot be accepted. Ask the workspace owner for a new invitation."
        case .invalidParticipant:
            "The participant cannot be invited to this workspace. Check the iCloud record name and permission."
        case .shareRecordMismatch:
            "The workspace share has changed. Sync and try again."
        case .concurrentChange:
            "The workspace was changed on another device at the same time. Try again."
        case .shareURLUnavailable:
            "iCloud did not return an invitation link. Try again."
        case .sentinelMismatch:
            "The workspace data in iCloud does not match this workspace. Contact your administrator."
        case .accountUnavailable:
            "Your iCloud account is unavailable. Sign in to iCloud and try again."
        case .permissionDenied:
            "iCloud did not allow this workspace request. Ask the workspace owner for access."
        case .quotaExceeded:
            "Your iCloud storage is full. Free up space and try again."
        case .requestFailed:
            "The iCloud request failed. Try again later."
        }
    }
}
