import Foundation

extension ContentSafetyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized, .invalidOperationAction:
            "You are not allowed to attach files to this workspace. Sync and try again, or ask an administrator."
        case .sourceSizeExceeded, .decodedSizeExceeded, .pageCountExceeded, .outputSizeExceeded, .outputDimensionsExceeded:
            "The file is too large. Choose a smaller file or a lower resolution."
        case .invalidSourceMetadata, .unsupportedSignature, .typeMismatch, .purposeTypeMismatch, .outputTypeMismatch:
            "That file type is not supported here. Choose a supported image or PDF file."
        case .animatedContent:
            "Animated images are not supported. Choose a still image."
        case .invalidDimensions, .invalidPDFPageBoxes, .missingSelectedPDFPage, .invalidSelectedPDFPage:
            "The file has unusable dimensions or pages. Choose a different file."
        case .decoderUnavailable, .decodeFailed:
            "The file could not be opened. It may be damaged. Choose a different file."
        }
    }
}

extension FileAttachmentStagingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRoot, .unexpectedRootItem:
            "The temporary storage for attachments is unavailable. Restart the app and try again."
        case .unknownLease, .invalidLifetime:
            "The selected file is no longer available because it waited too long. Choose the file again."
        case .namespaceMismatch:
            "The selected file belongs to another workspace. Choose the file again."
        case .leaseAlreadyClaimed, .invalidClaim:
            "The selected file has already been used. Choose the file again."
        case .stagedMetadataMismatch:
            "The selected file changed while it was being prepared. Choose the file again."
        }
    }
}

extension AttachmentEvidenceBindingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "You are not allowed to attach evidence to this work order. Sync and try again, or ask an administrator."
        case .invalidOwner:
            "The evidence cannot be attached to this item. Open the work order and try again."
        case .expiredStagingLease:
            "The selected file waited too long and is no longer available. Choose the file again."
        case .invalidReservation, .invalidReceipt, .invalidAttachmentIdentity:
            "The evidence could not be linked because its details are not valid. Attach the file again."
        case .bindingConflict:
            "This evidence is already linked to a work order. Choose a different file."
        case .invalidDigest:
            "The file changed while it was being attached. Choose the file again."
        }
    }
}
