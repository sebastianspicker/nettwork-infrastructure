import Foundation

extension AuthoritativeWorkOrderMutationFactoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .currentWorkOrderMismatch:
            "The work order changed while you were editing it. Reload it and try again."
        case .invalidPolicyVersion:
            "The workspace rules could not be applied. Sync and try again."
        }
    }
}

extension ResourceReservationLockFactoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingReservation:
            "The resources for this work order are not reserved. Reserve them and try again."
        case .invalidIntent, .invalidExpiry:
            "The reservation details are not valid. Review the work order and try again."
        }
    }
}

extension AuthoritativeRecordAssetError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDescriptor, .invalidInlineBytes, .invalidFileCapability:
            "The attached file could not be used. Attach the file again."
        case .digestMismatch:
            "The attached file changed while it was being saved. Attach the file again."
        }
    }
}

extension FloorPlanAssetBindingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPlannedAsset, .invalidBinding:
            "The floor plan file could not be linked. Choose the floor plan again."
        }
    }
}

extension AttachmentEvidenceActivationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidProvenance, .invalidBinding:
            "The evidence could not be linked because its details are not valid. Attach the file again."
        case .invalidQuotaLedger, .invalidReservationRelease:
            "The attachment storage could not be updated. Sync and try again."
        }
    }
}

extension AuthoritativeActivationMutationRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupported:
            "This kind of change is not supported on this device."
        }
    }
}

extension IntentDigestError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidLength, .invalidSchemaVersion:
            "The work order change could not be verified. Review the work order and try again."
        }
    }
}
