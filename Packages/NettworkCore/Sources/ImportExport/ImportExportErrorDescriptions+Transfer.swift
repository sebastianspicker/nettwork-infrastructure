import Foundation

extension WorkspaceTransferRecordError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownTable, .invalidColumns, .missingField, .unsupportedPublishedColumn:
            "The transfer file has missing or unexpected columns. Export the data again with the current app."
        case .invalidUUID, .invalidEnum, .invalidInteger, .invalidNumber, .invalidBoolean, .invalidDate, .invalidJSON, .invalidAddress:
            "The transfer file contains a value in the wrong format. Export the data again."
        case .nonCanonicalAddressID, .nonCanonicalPrefix, .nonCanonicalJSONL, .malformedJSONL:
            "The transfer file is not in the expected format. Export the data again."
        case .missingTombstoneDate, .unexpectedTombstoneDate, .duplicateResource:
            "The transfer file contains inconsistent records. Export the data again."
        case .unsupportedSchemaVersion:
            "The transfer file comes from an unsupported version. Export it again with the current app."
        case .rowTooLarge, .transferTooLarge, .tooManyRows:
            "The transfer is too large. Export a smaller workspace."
        }
    }
}

extension WorkspaceTransferStagingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBatchSize, .invalidMember, .invalidCheckpoint:
            "The transfer could not be prepared. Start the transfer again."
        }
    }
}

extension WorkspaceTransferValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedPayload, .resourceKeyMismatch, .tombstoneMetadataMismatch:
            "The transfer file contains damaged records. Export the data again."
        case .missingReference:
            "The transfer file refers to items that are not included. Export the complete workspace again."
        case .hierarchyValidationFailed, .topologyValidationFailed, .templateValidationFailed, .placementValidationFailed:
            "The structure of the transferred workspace is invalid. Export the data again."
        case .ipamValidationFailed, .operationalValidationFailed:
            "The addresses or work orders in the transfer are inconsistent. Export the data again."
        }
    }
}
