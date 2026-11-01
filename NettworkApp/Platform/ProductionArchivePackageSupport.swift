import Foundation
import ImportExport
import SwiftUI
import UniformTypeIdentifiers

enum ProductionCSVDirectoryPackageSource {
    static func source(at directoryURL: URL) throws -> ProductionCSVDirectoryImportSource {
        try ProductionCSVDirectoryImportSource(url: directoryURL)
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
        try nextChunk(maximumBytes: chunkSize)
    }

    /// Reads at most `maximumBytes` (and never more than the configured chunk
    /// size) so callers with their own bound can share this exact-size reader.
    func nextChunk(maximumBytes: Int) throws -> Data? {
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

        let chunk = try handle.read(upToCount: min(chunkSize, maximumBytes, remaining)) ?? Data()
        guard !chunk.isEmpty, chunk.count <= remaining else {
            throw ProductionArchiveDocumentAdapterError.unsafePackageEntry("archive payload")
        }
        bytesRead += chunk.count
        return chunk
    }
}
