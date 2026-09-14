import Foundation
import ImportExport
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A directory package. The visible filename is supplied by the export UI
    /// with the `.nettworkarchive` extension.
    static let nettworkArchive = UTType(exportedAs: "com.example.nettwork.archive", conformingTo: .package)
}

enum ProductionArchiveDocumentAdapterError: LocalizedError {
    case invalidPackage
    case inaccessiblePackage
    case unsafePackageEntry(String)
    case invalidExportDocument

    var errorDescription: String? {
        switch self {
        case .invalidPackage:
            "The selected item is not a .nettworkarchive directory package."
        case .inaccessiblePackage:
            "The selected archive is no longer available to the app."
        case .unsafePackageEntry(let path):
            "The selected archive contains an unsafe entry: \(path)."
        case .invalidExportDocument:
            "The verified archive could not be represented as a directory package."
        }
    }
}

/// A FileDocument writer for the already-verified core export document. It
/// creates only package directories required to hold the document's entries;
/// it never expands an external archive or synthesizes another payload.
struct NettworkArchiveDocument: FileDocument, @unchecked Sendable {
    static var readableContentTypes: [UTType] { [.nettworkArchive] }
    static var writableContentTypes: [UTType] { [.nettworkArchive] }

    private let package: FileWrapper

    init(exportDocument: ArchiveExportDocument) throws {
        package = try Self.packageWrapper(for: exportDocument.entries)
    }

    init(configuration: ReadConfiguration) throws {
        guard configuration.file.isDirectory else {
            throw ProductionArchiveDocumentAdapterError.invalidPackage
        }
        package = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        package
    }

    private static func packageWrapper(for entries: [String: Data]) throws -> FileWrapper {
        guard entries.count <= ArchiveSafetyLimits.maximumEntries else {
            throw ArchiveValidationError.archiveTooLarge
        }

        let root = FileWrapper(directoryWithFileWrappers: [:])
        var collisionKeys = Set<String>()
        var totalBytes = 0

        for (rawPath, bytes) in entries.sorted(by: { $0.key < $1.key }) {
            let path = try ArchivePathPolicy.normalized(rawPath)
            guard ArchivePathPolicy.isAllowed(path, kind: .regularFile),
                collisionKeys.insert(ArchivePathPolicy.collisionKey(path)).inserted,
                bytes.count <= ArchiveSafetyLimits.maximumEntryBytes,
                totalBytes <= ArchiveSafetyLimits.maximumExpandedBytes - bytes.count
            else {
                throw ProductionArchiveDocumentAdapterError.invalidExportDocument
            }
            totalBytes += bytes.count
            try addFile(bytes, at: path, to: root)
        }

        return root
    }

    private static func addFile(_ bytes: Data, at path: String, to root: FileWrapper) throws {
        let components = path.split(separator: "/").map(String.init)
        guard let filename = components.last else {
            throw ProductionArchiveDocumentAdapterError.invalidExportDocument
        }

        var directory = root
        for component in components.dropLast() {
            if let existing = directory.fileWrappers?[component] {
                guard existing.isDirectory else {
                    throw ProductionArchiveDocumentAdapterError.invalidExportDocument
                }
                directory = existing
                continue
            }

            let child = FileWrapper(directoryWithFileWrappers: [:])
            child.preferredFilename = component
            directory.addFileWrapper(child)
            directory = child
        }

        guard directory.fileWrappers?[filename] == nil else {
            throw ProductionArchiveDocumentAdapterError.invalidExportDocument
        }
        let file = FileWrapper(regularFileWithContents: bytes)
        file.preferredFilename = filename
        directory.addFileWrapper(file)
    }
}

/// Enumerates one user-selected `.nettworkarchive` package without following
/// links. The core verifier remains the owner of archive integrity checks;
/// this adapter only exposes bounded, deterministic filesystem entries.
final class ProductionArchivePackageEntrySource: ArchiveEntrySource, ArchiveEntrySourceAccessLifetime, @unchecked Sendable {
    private struct IndexedEntry {
        let metadata: ArchiveEntryMetadata
        let url: URL
    }

    private let chunkSize: Int
    private let lifetime: SecurityScopedPackageAccess
    /// The package tree is walked and normalized exactly once while its
    /// security scope is live. Readers perform a constant-time lookup here.
    private let orderedEntries: [ArchiveEntryMetadata]
    private let entriesByPath: [String: IndexedEntry]

    init(url: URL, chunkSize: Int = 64 * 1_024) throws {
        guard url.isFileURL,
            url.pathExtension.caseInsensitiveCompare(ArchiveLayout.nettworkarchive.rawValue) == .orderedSame,
            (1...64 * 1_024).contains(chunkSize)
        else {
            throw ProductionArchiveDocumentAdapterError.invalidPackage
        }

        let didStartAccess = url.startAccessingSecurityScopedResource()
        do {
            let root = url.standardizedFileURL
            let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw ProductionArchiveDocumentAdapterError.invalidPackage
            }
            let index = try Self.makeIndex(root: root)
            self.chunkSize = chunkSize
            orderedEntries = index.entries
            entriesByPath = index.entriesByPath
            lifetime = SecurityScopedPackageAccess(url: url, didStartAccess: didStartAccess)
        } catch {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    deinit { close() }

    func close() {
        lifetime.close()
    }

    func entries() throws -> [ArchiveEntryMetadata] {
        try lifetime.requireOpen()
        return orderedEntries
    }

    func reader(for entry: ArchiveEntryMetadata) throws -> any ArchiveEntryReader {
        try lifetime.requireOpen()
        guard let indexedEntry = entriesByPath[entry.path],
            indexedEntry.metadata == entry,
            entry.kind == .regularFile
        else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(entry.path)
        }
        let values = try indexedEntry.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            values.fileSize == entry.uncompressedSize
        else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(entry.path)
        }
        return try ProductionArchivePackageEntryReader(url: indexedEntry.url, expectedSize: entry.uncompressedSize, chunkSize: chunkSize)
    }

    private static func makeIndex(root: URL) throws -> (entries: [ArchiveEntryMetadata], entriesByPath: [String: IndexedEntry]) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey], options: []
            )
        else {
            throw ProductionArchiveDocumentAdapterError.inaccessiblePackage
        }

        var entries: [ArchiveEntryMetadata] = []
        var entriesByPath: [String: IndexedEntry] = [:]
        var collisionKeys = Set<String>()
        var totalBytes = 0

        for case let url as URL in enumerator {
            let path = try relativePath(for: url, root: root)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(path)
            }
            let (kind, size) = try entryKindAndSize(values, path: path)
            totalBytes = try admittedTotalBytes(
                path: path, kind: kind, size: size, entryCount: entries.count, currentTotal: totalBytes,
                collisionKeys: &collisionKeys)
            let metadata = ArchiveEntryMetadata(path: path, kind: kind, uncompressedSize: size, compressedSize: size)
            entries.append(metadata)
            entriesByPath[path] = IndexedEntry(metadata: metadata, url: url)
        }

        return (entries.sorted { $0.path < $1.path }, entriesByPath)
    }

    private static func entryKindAndSize(_ values: URLResourceValues, path: String) throws -> (ArchiveEntryKind, Int) {
        if values.isDirectory == true { return (.directory, 0) }
        if values.isRegularFile == true, let size = values.fileSize, size >= 0 {
            return (.regularFile, size)
        }
        throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(path)
    }

    private static func admittedTotalBytes(
        path: String, kind: ArchiveEntryKind, size: Int, entryCount: Int, currentTotal: Int, collisionKeys: inout Set<String>
    ) throws -> Int {
        guard ArchivePathPolicy.isAllowed(path, kind: kind),
            collisionKeys.insert(ArchivePathPolicy.collisionKey(path)).inserted
        else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(path)
        }
        guard entryCount < ArchiveSafetyLimits.maximumEntries else {
            throw ArchiveValidationError.archiveTooLarge
        }
        if kind == .regularFile {
            guard size <= ArchiveSafetyLimits.maximumEntryBytes,
                currentTotal <= ArchiveSafetyLimits.maximumExpandedBytes - size
            else {
                throw ArchiveValidationError.archiveTooLarge
            }
        }
        let (next, overflow) = currentTotal.addingReportingOverflow(size)
        guard !overflow else { throw ArchiveValidationError.archiveTooLarge }
        return next
    }

    private static func relativePath(for url: URL, root: URL) throws -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(rootPath) else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(url.path)
        }
        return try ArchivePathPolicy.normalized(String(url.path.dropFirst(rootPath.count)))
    }
}

/// Reads a selected CSV directory in bounded chunks and hands only typed,
/// basename entries to the core CSV document mapper. It deliberately has no
/// UI policy and keeps the security scope limited to this conversion.
