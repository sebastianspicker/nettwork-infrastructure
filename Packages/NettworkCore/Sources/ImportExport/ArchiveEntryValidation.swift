import Foundation

/// Entry-level checks shared by both archive verifiers and the exporter, so they cannot drift apart.
enum ArchiveEntryValidation {
    static func normalize(
        _ entries: [ArchiveEntryMetadata]
    ) throws -> [(ArchiveEntryMetadata, String)] {
        guard entries.count <= ArchiveSafetyLimits.maximumEntries else {
            throw ArchiveValidationError.archiveTooLarge
        }
        var collisionKeys = Set<String>()
        var declaredTotal = 0
        var normalized: [(ArchiveEntryMetadata, String)] = []
        for entry in entries {
            try Task.checkCancellation()
            let path = try ArchivePathPolicy.normalized(entry.path)
            guard collisionKeys.insert(ArchivePathPolicy.collisionKey(path)).inserted else {
                throw ArchiveValidationError.duplicatePath(path)
            }
            try validateKind(entry.kind, path: path)
            try validateSizes(entry, path: path)
            guard declaredTotal <= ArchiveSafetyLimits.maximumExpandedBytes - entry.uncompressedSize else {
                throw ArchiveValidationError.archiveTooLarge
            }
            declaredTotal += entry.uncompressedSize
            normalized.append((entry, path))
        }
        for required in requiredPaths {
            guard normalized.contains(where: { $0.1 == required }) else {
                throw ArchiveValidationError.requiredEntryMissing(required)
            }
        }
        return normalized
    }

    static let requiredPaths = [
        ArchiveLayout.manifestPath, ArchiveLayout.recordsPath, ArchiveLayout.auditPath,
        ArchiveLayout.completionPath,
    ]

    private static func validateKind(_ kind: ArchiveEntryKind, path: String) throws {
        guard !ArchivePathPolicy.isAllowed(path, kind: kind) else { return }
        if kind != .regularFile && kind != .directory {
            throw ArchiveValidationError.forbiddenEntryKind(path)
        }
        throw ArchiveValidationError.unknownEntry(path)
    }

    static func validateSizes(_ entry: ArchiveEntryMetadata, path: String) throws {
        guard entry.uncompressedSize >= 0, entry.compressedSize >= 0,
            entry.uncompressedSize <= ArchiveSafetyLimits.maximumEntryBytes
        else { throw ArchiveValidationError.invalidEntryMetadata(path) }
        guard entry.uncompressedSize > 0 else { return }
        guard entry.compressedSize > 0,
            entry.compressedSize <= Int.max / ArchiveSafetyLimits.maximumExpansionRatio
        else { throw ArchiveValidationError.invalidEntryMetadata(path) }
        guard entry.uncompressedSize <= entry.compressedSize * ArchiveSafetyLimits.maximumExpansionRatio else {
            throw ArchiveValidationError.expansionLimitExceeded
        }
    }

    /// Counts non-empty lines: blank lines are not records, and a final line without a newline counts.
    static func countJSONL(_ data: Data) throws -> Int {
        var count = 0
        var hasBytes = false
        var scanned = 0
        func closeLine() throws {
            guard hasBytes else { return }
            guard count < WorkspaceTransferLimits.maximumRows else { throw ArchiveValidationError.manifestMismatch }
            count += 1
            hasBytes = false
        }
        for byte in data {
            scanned += 1
            if scanned & 0xFFFF == 0 { try Task.checkCancellation() }
            if byte == 0x0A { try closeLine() } else { hasBytes = true }
        }
        try closeLine()
        return count
    }
}
