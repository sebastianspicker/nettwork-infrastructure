import Foundation

extension ProductionAttachmentEvidenceAuthorityError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidPolicy, .namespaceMismatch, .workOrderOwnershipMismatch:
            "The request was not authorized for this workspace. Sync and try again."
        case .invalidReservation, .expiredReservation:
            "The attachment upload is no longer valid. Attach the file again."
        case .invalidWorkOrder, .evidenceNotBoundToWorkOrderIntent:
            "The evidence does not match the work order. Open the work order and attach the file again."
        case .malformedAuthoritativeRecord, .receiptMismatch:
            "The attachment could not be confirmed. Sync and try again."
        case .quotaExceeded:
            "The attachment storage limit has been reached. Remove older attachments and try again."
        }
    }
}

extension ProductionFloorPlanPDFInspectorError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized:
            "You are not allowed to add floor plans to this workspace. Sync and try again, or ask an administrator."
        case .invalidMetadata, .invalidChunk:
            "The floor plan file could not be read completely. Choose the file again."
        case .invalidSignature, .invalidDocument, .invalidPageBoxes:
            "The floor plan is not a usable PDF. Choose a different file."
        }
    }
}

extension ProductionFloorPlanServiceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .staleAuthorization:
            "Your permissions changed. Sync and try again."
        case .invalidFloor:
            "The selected floor no longer exists. Choose another floor."
        case .invalidCoordinates:
            "The position on the floor plan is not valid. Pick a point inside the floor plan."
        case .pdfInspectionUnavailable, .invalidPreviewDescriptor:
            "The floor plan could not be prepared. Choose the file again."
        }
    }
}

extension ProductionFloorPlanAssetAuthorityError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .staleAuthorization:
            "Your permissions changed. Sync and try again."
        case .invalidDescriptor, .receiptMismatch:
            "The floor plan could not be saved. Choose the file again."
        case .malformedAuthoritativeRecord, .invalidWorkOrder:
            "The floor plan data is incomplete. Sync and try again."
        }
    }
}

extension ProductionAuditExportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .namespaceMismatch:
            "The audit history belongs to a different workspace. Open that workspace and export again."
        case .invalidStagingRoot, .unknownCapability:
            "The temporary storage for the export is unavailable. Restart the app and export again."
        case .destinationExists:
            "A file with that name already exists. Choose a different name or location."
        case .invalidDestination:
            "The export destination cannot be used. Choose a different location."
        case .malformedAuditRecord:
            "Part of the audit history is damaged and could not be exported. Sync and export again."
        }
    }
}

extension ProductionArchiveAssetSourceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .malformedAssetRecord, .duplicateAsset:
            "An attached file could not be included in the archive. Sync and export again."
        case .corruptAsset:
            "An attached file is damaged and could not be exported. Attach the file again."
        }
    }
}

extension ProductionWorkspaceTransferAuthorityError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .namespaceMismatch, .bootstrapSentinelMissing, .malformedBootstrapSentinel:
            "The workspace is not ready for this import. Sync and start the import again."
        case .workspaceNotEmpty:
            "Import is only possible into an empty workspace. Create a new workspace and import there."
        case .malformedMirrorRecord, .unsupportedMirrorTombstone, .duplicateActivationResource:
            "The workspace data is inconsistent. Sync and try again."
        case .nonCanonicalTransfer, .malformedStagedTransfer, .receiptMismatch:
            "The transfer data is not valid. Start the transfer again."
        case .malformedArchiveAudit, .malformedArchiveOperationalState, .missingArchiveAsset, .invalidArchiveAsset:
            "The archive is incomplete or damaged. Export the archive again."
        case .archiveSourceMismatch, .archiveRootMismatch:
            "The archive does not belong to this workspace. Choose the correct archive."
        case .legacyAggregateRequiresMigration:
            "The workspace data comes from an older version and cannot be imported. Contact support."
        }
    }
}
