import Foundation
import ImportExport
import SwiftUI
import UniformTypeIdentifiers

enum ProductionCSVDirectoryPackageSource {
    static func source(at directoryURL: URL) throws -> ProductionCSVDirectoryImportSource {
        try ProductionCSVDirectoryImportSource(url: directoryURL)
    }

    /// Compatibility path for callers that still need an in-memory document.
    static func document(at directoryURL: URL) throws -> CSVImportDocument {
        let source = try source(at: directoryURL)
        defer { source.close() }
        let files = try source.fileMetadata().map { metadata -> CSVImportDocument.File in
            var reader = try source.openFile(metadata)
            var bytes = Data()
            while let chunk = try reader.nextChunk() {
                guard chunk.count <= CSVImportLimits.maximumFileBytes - bytes.count else {
                    throw CSVImportError.fileTooLarge
                }
                bytes.append(chunk)
            }
            return try CSVImportDocument.File(table: metadata.table, bytes: bytes)
        }
        return try CSVImportDocument(files: files)
    }
}

final class SecurityScopedPackageAccess: @unchecked Sendable {
    private let url: URL
    private let didStartAccess: Bool
    private let lock = NSLock()
    private var isClosed = false

    init(url: URL, didStartAccess: Bool) {
        self.url = url
        self.didStartAccess = didStartAccess
    }

    deinit { close() }

    func requireOpen() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else {
            throw ProductionArchiveDocumentAdapterError.inaccessiblePackage
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        if didStartAccess {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

final class ProductionArchivePackageEntryReader: ArchiveEntryReader, @unchecked Sendable {
    private let handle: FileHandle
    private let expectedSize: Int
    private let chunkSize: Int
    private let lock = NSLock()
    private var bytesRead = 0
    private var isFinished = false

    init(url: URL, expectedSize: Int, chunkSize: Int) throws {
        guard expectedSize >= 0, chunkSize > 0 else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry(url.lastPathComponent)
        }
        handle = try FileHandle(forReadingFrom: url)
        self.expectedSize = expectedSize
        self.chunkSize = chunkSize
    }

    deinit { try? handle.close() }

    func nextChunk() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return nil }

        let remaining = expectedSize - bytesRead
        guard remaining >= 0 else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry("archive payload")
        }
        if remaining == 0 {
            let trailing = try handle.read(upToCount: 1) ?? Data()
            guard trailing.isEmpty else {
                throw ProductionArchiveDocumentAdapterError.unsafePackageEntry("archive payload")
            }
            isFinished = true
            return nil
        }

        let chunk = try handle.read(upToCount: min(chunkSize, remaining)) ?? Data()
        guard !chunk.isEmpty, chunk.count <= remaining else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry("archive payload")
        }
        bytesRead += chunk.count
        return chunk
    }
}
