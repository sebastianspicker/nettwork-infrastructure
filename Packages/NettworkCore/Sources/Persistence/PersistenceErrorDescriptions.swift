import Foundation

extension PersistenceStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidNamespace, .invalidNamespaceLease, .invalidCloudRecordNameIdentity, .malformedStoredValue:
            "The saved workspace data could not be read. Restart the app, and sync again if the problem remains."
        case .invalidMirrorRecord, .staleMirrorUpdate, .tombstoneResurrection, .mirrorMaintenanceInvalid, .mirrorMaintenanceIncomplete:
            "The synced copy of your workspace is out of date or inconsistent. Sync again and retry."
        case .duplicateOperation, .unknownOperation, .invalidOperation, .invalidLifecycleTransition, .invalidReceipt,
            .invalidReservationAcknowledgement:
            "The pending change could not be recorded. Review the change and submit it again."
        case .missingDependency, .missingSharedResourceDependency:
            "The change depends on an item that is not available. Sync and try again."
        case .missingAttachment, .attachmentCorrupt:
            "An attached file is missing or damaged. Attach the file again."
        case .invalidReadLimit, .inventoryProjectionIncomplete:
            "The inventory could not be loaded completely. Reload and try again."
        case .cloudRecordNameIdentityCapacityExceeded, .inventorySearchIndexCapacityExceeded, .inventoryProjectionTraversalExceeded,
            .inventoryProjectionNodeCapacityExceeded, .conflictResourceIndexCapacityExceeded, .mirrorMaintenanceCapacityExceeded:
            "The workspace is too large to process on this device. Split it into smaller workspaces."
        case .inventorySearchTextTooLarge:
            "An item contains too much text to be searched. Shorten its notes or description."
        }
    }
}

extension AttachmentEvidencePersistenceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidQuotaPolicy, .invalidReservation, .invalidProvenance, .invalidEvidenceBinding, .receiptMismatch:
            "The attachment could not be saved because its details are not valid. Attach the file again."
        case .reservationConflict, .attachmentAlreadyBound:
            "This attachment is already linked to a work order. Choose a different file."
        case .reservationExpired:
            "The attachment upload expired before it was completed. Attach the file again."
        case .quotaExceeded:
            "The attachment storage limit has been reached. Remove older attachments and try again."
        }
    }
}

extension PersistenceMigrationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .legacyEnvelopeUnavailable, .legacyBaseStateUnavailable, .legacyNamespaceMismatch:
            "Data from an earlier version of the app could not be upgraded. Restore from a backup or contact support."
        }
    }
}
