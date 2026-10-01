import Darwin
import Foundation
import ImportExport

private struct ProductionCSVFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int

    static func read(path: String, descriptor: Int32? = nil) throws -> Self {
        var value = stat()
        let result = if let descriptor { fstat(descriptor, &value) } else { lstat(path, &value) }
        guard result == 0, (value.st_mode & S_IFMT) == S_IFREG,
            value.st_size >= 0, value.st_size <= Int64(Int.max)
        else { throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(path) }
        return Self(
            device: UInt64(value.st_dev), inode: UInt64(value.st_ino),
            size: Int(value.st_size))
    }
}

final class ProductionCSVDirectoryImportSource: CSVImportSource, CSVImportSourceAccessLifetime, @unchecked Sendable {
    private struct IndexedFile {
        let metadata: CSVImportFileMetadata
        let url: URL
        let identity: ProductionCSVFileIdentity
    }

    private let lifetime: SecurityScopedPackageAccess
    private let orderedMetadata: [CSVImportFileMetadata]
    private let filesByTable: [CSVTable: IndexedFile]
    private let chunkSize: Int

    init(url: URL, chunkSize: Int = 64 * 1_024) throws {
        guard url.isFileURL, (1...64 * 1_024).contains(chunkSize) else {
            throw ProductionArchiveDocumentAdapterError.invalidPackage
        }
        let didStartAccess = url.startAccessingSecurityScopedResource()
        do {
            let indexed = try Self.index(url.standardizedFileURL)
            lifetime = SecurityScopedPackageAccess(url: url, didStartAccess: didStartAccess)
            orderedMetadata = indexed.map(\.metadata)
            filesByTable = Dictionary(uniqueKeysWithValues: indexed.map { ($0.metadata.table, $0) })
            self.chunkSize = chunkSize
        } catch {
            if didStartAccess { url.stopAccessingSecurityScopedResource() }
            throw error
        }
    }

    deinit { lifetime.close() }

    func fileMetadata() throws -> [CSVImportFileMetadata] {
        try lifetime.requireOpen()
        return orderedMetadata
    }

    func openFile(_ file: CSVImportFileMetadata) throws -> AnyCSVByteChunkSource {
        try lifetime.requireOpen()
        guard let indexed = filesByTable[file.table], indexed.metadata == file else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(file.table.rawValue)
        }
        guard try ProductionCSVFileIdentity.read(path: indexed.url.path) == indexed.identity else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(indexed.url.lastPathComponent)
        }
        let values = try indexed.url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            values.fileSize == file.declaredByteCount
        else { throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(indexed.url.lastPathComponent) }
        return AnyCSVByteChunkSource(
            try ProductionCSVFileChunkSource(
                url: indexed.url, expectedSize: file.declaredByteCount,
                expectedIdentity: indexed.identity, chunkSize: chunkSize,
                lifetime: lifetime))
    }

    func close() { lifetime.close() }

    private static func index(_ directory: URL) throws -> [IndexedFile] {
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ProductionArchiveDocumentAdapterError.invalidPackage
        }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [])
        guard !urls.isEmpty, urls.count <= CSVTable.allCases.count else { throw CSVImportError.importTooLarge }

        var filenames = Set<String>()
        var foldedFilenames = Set<String>()
        var totalBytes = 0
        var indexed: [IndexedFile] = []
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let table = try table(
                for: url.lastPathComponent, filenames: &filenames,
                foldedFilenames: &foldedFilenames)
            let file = try indexedFile(url: url, table: table, bytesBefore: totalBytes)
            totalBytes += file.metadata.declaredByteCount
            indexed.append(file)
        }
        return indexed.sorted { $0.metadata.table.rawValue < $1.metadata.table.rawValue }
    }

    private static func table(
        for filename: String, filenames: inout Set<String>,
        foldedFilenames: inout Set<String>
    ) throws -> CSVTable {
        guard filenames.insert(filename).inserted else {
            throw CSVImportDocumentSourceError.duplicateFilename(filename)
        }
        guard foldedFilenames.insert(filename.lowercased()).inserted else {
            throw CSVImportDocumentSourceError.filenameCaseCollision(filename)
        }
        if let table = CSVTable.allCases.first(where: {
            CSVImportDocumentFilenames.filename(for: $0) == filename
        }) {
            return table
        }
        guard
            !CSVTable.allCases.contains(where: {
                CSVImportDocumentFilenames.filename(for: $0)
                    .caseInsensitiveCompare(filename) == .orderedSame
            })
        else {
            throw CSVImportDocumentSourceError.filenameCaseCollision(filename)
        }
        throw CSVImportDocumentSourceError.unknownFilename(filename)
    }

    private static func indexedFile(
        url: URL, table: CSVTable, bytesBefore: Int
    ) throws -> IndexedFile {
        let filename = url.lastPathComponent
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isDirectory != true,
            values.isSymbolicLink != true, let size = values.fileSize, size >= 0,
            size <= CSVImportLimits.maximumFileBytes
        else { throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(filename) }
        guard size <= CSVImportLimits.maximumImportBytes - bytesBefore else {
            throw CSVImportError.importTooLarge
        }
        guard let template = CSVSchemaV2.templates[table] else {
            throw CSVImportDocumentError.missingSchema(table.rawValue)
        }
        let identity = try ProductionCSVFileIdentity.read(path: url.path)
        guard identity.size == size else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(filename)
        }
        return .init(
            metadata: .init(template: template, declaredByteCount: size),
            url: url, identity: identity)
    }
}

private struct ProductionCSVFileChunkSource: CSVByteChunkSource, @unchecked Sendable {
    private final class Storage: @unchecked Sendable {
        let handle: FileHandle
        let expectedSize: Int
        let chunkSize: Int
        let lifetime: SecurityScopedPackageAccess
        var bytesRead = 0
        var finished = false

        init(
            url: URL, expectedSize: Int,
            expectedIdentity: ProductionCSVFileIdentity,
            chunkSize: Int, lifetime: SecurityScopedPackageAccess
        ) throws {
            handle = try FileHandle(forReadingFrom: url)
            guard
                try ProductionCSVFileIdentity.read(
                    path: url.path, descriptor: handle.fileDescriptor) == expectedIdentity
            else {
                try? handle.close()
                throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(url.lastPathComponent)
            }
            self.expectedSize = expectedSize
            self.chunkSize = chunkSize
            self.lifetime = lifetime
        }

        deinit { try? handle.close() }

        func nextChunk() throws -> Data? {
            try lifetime.requireOpen()
            guard !finished else { return nil }
            let remaining = expectedSize - bytesRead
            guard remaining >= 0 else { throw CSVImportError.fileTooLarge }
            if remaining == 0 {
                guard (try handle.read(upToCount: 1) ?? Data()).isEmpty else { throw CSVImportError.fileTooLarge }
                finished = true
                return nil
            }
            let chunk = try handle.read(upToCount: min(chunkSize, remaining)) ?? Data()
            guard !chunk.isEmpty, chunk.count <= remaining else { throw CSVImportError.fileTooLarge }
            bytesRead += chunk.count
            return chunk
        }
    }

    private let storage: Storage

    init(
        url: URL, expectedSize: Int, expectedIdentity: ProductionCSVFileIdentity,
        chunkSize: Int, lifetime: SecurityScopedPackageAccess
    ) throws {
        storage = try Storage(
            url: url, expectedSize: expectedSize,
            expectedIdentity: expectedIdentity, chunkSize: chunkSize,
            lifetime: lifetime)
    }

    mutating func nextChunk() throws -> Data? { try storage.nextChunk() }
}
