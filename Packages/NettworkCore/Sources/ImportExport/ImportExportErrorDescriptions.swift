import Foundation

extension ArchiveValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion, .incompatibleReader:
            "This archive was created by a different version of the app. Update the app or export the archive again."
        case .archiveTooLarge, .expansionLimitExceeded:
            "The archive is too large to open safely. Export a smaller archive."
        case .manifestMismatch, .completionMarkerMismatch, .approvalMismatch, .hashMismatch, .sizeMismatch, .auditChainInvalid:
            "The archive is damaged or was changed after export. Export the archive again."
        case .invalidPath, .duplicatePath, .forbiddenEntryKind, .unknownEntry, .requiredEntryMissing, .invalidEntryMetadata:
            "The archive contains unexpected content and was not opened. Export the archive again."
        case .archiveDecodeFailed:
            "The archive could not be read. Choose a different archive."
        }
    }
}

extension FileBackedStagingError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidRoot:
            "The temporary storage for the transfer is unavailable. Restart the app and try again."
        case .invalidStagingHandle, .stagingNotReady:
            "The prepared transfer is no longer available. Start the transfer again."
        case .stagedPayloadMismatch, .restoreSourceMismatch, .invalidArchiveEntry:
            "The prepared data changed unexpectedly. Start the transfer again."
        case .activationReceiptMismatch:
            "The transfer could not be confirmed. Sync and start the transfer again."
        }
    }
}

extension CSVWorkspaceExportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .nonFiniteNumber:
            "A value in the workspace is not a valid number, so the export was stopped. Correct the value and export again."
        }
    }
}

extension CSVImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .fileTooLarge, .importTooLarge, .cellTooLarge, .rowTooLarge, .tooManyColumns, .tooManyRows:
            "The CSV file is too large to import. Split it into smaller files."
        case .malformedUTF8, .nulByte:
            "The CSV file is not valid text. Save it as UTF-8 and try again."
        case .bareCarriageReturn, .bareLineFeed, .unterminatedQuotedField, .invalidQuotePlacement:
            "The CSV file is badly formatted. Check line breaks and quotation marks, then try again."
        case .duplicateHeader, .unexpectedHeader, .duplicateTable:
            "The CSV column headings are not what was expected. Use a file exported from Nettwork."
        case .unsupportedSchemaVersion:
            "The CSV file comes from an unsupported version. Export it again with the current app."
        case .rowColumnCount:
            "A row in the CSV file has the wrong number of columns. Check the file and try again."
        }
    }
}

extension CSVImportDocumentError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            "The selected CSV document contains no files. Choose a complete export."
        case .missingSchema:
            "The selected CSV document is missing required files. Choose a complete export."
        }
    }
}

extension CSVImportDocumentSourceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .directory, .pathComponent, .unknownFilename:
            "The selected CSV folder contains unexpected files. Choose a folder exported from Nettwork."
        case .duplicateFilename, .filenameCaseCollision:
            "The selected CSV folder contains files with the same name. Remove the duplicates and try again."
        }
    }
}

extension ImportAuthorizationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .actionMismatch, .staleContext, .namespaceMismatch:
            "The import is no longer valid for this workspace. Sync and start the import again."
        case .administratorRequired, .writePermissionRequired:
            "You do not have permission to import into this workspace. Ask an administrator."
        }
    }
}

extension ImportPlanError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .workspaceNotEmpty:
            "Import is only possible into an empty workspace. Create a new workspace and import there."
        case .invalidCounts, .invalidSchemaRecord, .dryRunFailed:
            "The import file failed its checks. Export the data again and retry."
        case .inputDigestMismatch, .invalidStagingHandle, .activationReceiptMismatch:
            "The file changed during the import. Start the import again."
        case .activationConflict:
            "The workspace changed during the import. Sync and start the import again."
        }
    }
}
