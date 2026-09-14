import Foundation
import NetworkModel
import WorkspaceChangeControl

public struct FileBackedArchiveEntrySource: ArchiveEntrySource {
    private let root: URL
    private let chunkSize: Int

    public init(root: URL, chunkSize: Int = 64 * 1_024) throws {
        guard chunkSize > 0 else { throw FileBackedStagingError.invalidArchiveEntry }
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        self.chunkSize = chunkSize
        try FileBackedStagingFiles.validateDirectory(self.root)
    }

    public func entries() throws -> [ArchiveEntryMetadata] {
        let manager = FileManager.default
        guard
            let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [])
        else { throw FileBackedStagingError.invalidRoot }
        var result: [ArchiveEntryMetadata] = []
        for case let url as URL in enumerator {
            let relative = try relativePath(for: url)
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let kind: ArchiveEntryKind
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                kind = .symbolicLink
            } else if values.isDirectory == true {
                kind = .directory
            } else if values.isRegularFile == true {
                kind = .regularFile
            } else {
                kind = .special
            }
            let size = values.fileSize ?? 0
            result.append(ArchiveEntryMetadata(path: relative, kind: kind, uncompressedSize: size, compressedSize: size))
        }
        return result.sorted { $0.path < $1.path }
    }

    public func reader(for entry: ArchiveEntryMetadata) throws -> any ArchiveEntryReader {
        let path = try ArchivePathPolicy.normalized(entry.path)
        let url = root.appendingPathComponent(path, isDirectory: false)
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true,
            values.isSymbolicLink != true,
            values.fileSize == entry.uncompressedSize
        else {
            throw FileBackedStagingError.invalidArchiveEntry
        }
        return try FileBackedArchiveEntryReader(
            url: url, expectedSize: entry.uncompressedSize,
            chunkSize: chunkSize)
    }

    private func relativePath(for url: URL) throws -> String {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalPath.hasPrefix(rootPath) else { throw FileBackedStagingError.invalidArchiveEntry }
        return try ArchivePathPolicy.normalized(String(canonicalPath.dropFirst(rootPath.count)))
    }
}

private final class FileBackedArchiveEntryReader: ArchiveEntryReader, @unchecked Sendable {
    private let handle: FileHandle
    private let expectedSize: Int
    private let chunkSize: Int
    private var bytesRead = 0
    private var reachedEnd = false

    init(url: URL, expectedSize: Int, chunkSize: Int) throws {
        guard expectedSize >= 0 else { throw FileBackedStagingError.invalidArchiveEntry }
        handle = try FileHandle(forReadingFrom: url)
        self.expectedSize = expectedSize
        self.chunkSize = chunkSize
    }

    func nextChunk() throws -> Data? {
        guard !reachedEnd else { return nil }
        let remaining = expectedSize - bytesRead
        guard remaining >= 0 else { throw FileBackedStagingError.invalidArchiveEntry }
        if remaining == 0 {
            let trailing = try handle.read(upToCount: 1) ?? Data()
            guard trailing.isEmpty else { throw FileBackedStagingError.invalidArchiveEntry }
            reachedEnd = true
            return nil
        }
        let chunk = try handle.read(upToCount: min(chunkSize, remaining)) ?? Data()
        guard !chunk.isEmpty, chunk.count <= remaining else {
            throw FileBackedStagingError.invalidArchiveEntry
        }
        bytesRead += chunk.count
        return chunk
    }

    deinit { try? handle.close() }
}

/// The restore authority owns the fresh-target predicate, semantic validation,
/// and the one atomic visibility transition. The local adapter supplies only a
/// verified, immutable archive value to that authority.
