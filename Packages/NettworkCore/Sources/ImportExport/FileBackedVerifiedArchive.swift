import ContentSafety
import CryptoKit
import Foundation
import WorkspaceChangeControl

public struct FileBackedVerifiedArchiveEntry: Hashable, Sendable {
    public let metadata: ArchiveEntryMetadata
    public let digest: ArchiveDigest

    public init(metadata: ArchiveEntryMetadata, digest: ArchiveDigest) {
        self.metadata = metadata
        self.digest = digest
    }
}

/// A verified archive descriptor. Payload bytes remain behind an opaque,
/// protected staging handle and are opened one entry at a time.
public struct FileBackedVerifiedArchive: Sendable {
    public let manifest: ArchiveManifest
    public let rootSHA256: String
    public let entries: [FileBackedVerifiedArchiveEntry]
    let storage: FileBackedVerifiedArchiveStorage
    private let entriesByPath: [String: FileBackedVerifiedArchiveEntry]
    private let declaredAssets: Set<ArchiveAsset>

    init(
        manifest: ArchiveManifest,
        rootSHA256: String,
        entries: [FileBackedVerifiedArchiveEntry],
        storage: FileBackedVerifiedArchiveStorage
    ) {
        self.manifest = manifest
        self.rootSHA256 = rootSHA256
        self.entries = entries
        self.storage = storage
        // Built once: per-asset lookups during restore would otherwise be O(n^2).
        entriesByPath = Dictionary(entries.map { ($0.metadata.path, $0) }, uniquingKeysWith: { first, _ in first })
        declaredAssets = Set(manifest.assets)
    }

    public func readEntry(at path: String) throws -> Data {
        try storage.readEntry(at: path, entries: entriesByPath)
    }

    public func assetDescriptor(
        for asset: ArchiveAsset, fieldName: String
    ) throws -> CloudRecordAssetDescriptor {
        guard declaredAssets.contains(asset) else {
            throw ArchiveValidationError.manifestMismatch
        }
        let path = try ArchivePathPolicy.normalized(asset.relativePath)
        let bytes = try readEntry(at: path)
        guard bytes.count == asset.byteCount,
            HexDigest.string(SHA256.hash(data: bytes)) == asset.sha256
        else { throw ArchiveValidationError.hashMismatch(path) }
        return try CloudRecordAssetDescriptor(
            id: asset.id, fieldName: fieldName, sha256: asset.sha256,
            contentType: asset.contentType, byteCount: asset.byteCount,
            storage: .durableFile(try storage.fileURL(at: path, entries: entriesByPath)))
    }

    /// Explicit preview ownership cleanup. Once a restore store adopts the
    /// payload, closing an old preview cannot remove the adopted directory.
    public func discardIfUnadopted() { storage.discardIfUnadopted() }

    func adoptPayload(into destination: URL) throws {
        try storage.adopt(into: destination)
    }
}

final class FileBackedVerifiedArchiveStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var root: URL?
    private var adopted = false

    init(root: URL) { self.root = root.standardizedFileURL }

    deinit { discardIfUnadopted() }

    func readEntry(
        at rawPath: String,
        entries: [String: FileBackedVerifiedArchiveEntry]
    ) throws -> Data {
        let path = try ArchivePathPolicy.normalized(rawPath)
        guard let entry = entries[path],
            entry.metadata.kind == .regularFile,
            entry.metadata.uncompressedSize <= ArchiveSafetyLimits.maximumEntryBytes
        else { throw ArchiveValidationError.unknownEntry(path) }
        let root = try currentRoot()
        let url = root.appendingPathComponent(path, isDirectory: false)
        let data = try FileBackedStagingFiles.readPrivate(
            url, maximumBytes: ArchiveSafetyLimits.maximumEntryBytes)
        guard data.count == entry.digest.size,
            HexDigest.string(SHA256.hash(data: data)) == entry.digest.sha256
        else { throw ArchiveValidationError.hashMismatch(path) }
        return data
    }

    func adopt(into destination: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !adopted, let source = root else { throw FileBackedStagingError.stagingNotReady }
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw FileBackedStagingError.invalidRoot
        }
        try FileBackedStagingFiles.ensurePrivateDirectory(destination.deletingLastPathComponent())
        // The durable restore store owns the adopted copy; it must not carry the sweep marker.
        try? FileManager.default.removeItem(at: source.appendingPathComponent(StagingSweep.markerName))
        try FileManager.default.moveItem(at: source, to: destination)
        root = destination.standardizedFileURL
        adopted = true
    }

    func fileURL(
        at rawPath: String, entries: [String: FileBackedVerifiedArchiveEntry]
    ) throws -> URL {
        let path = try ArchivePathPolicy.normalized(rawPath)
        guard entries[path]?.metadata.kind == .regularFile else { throw ArchiveValidationError.unknownEntry(path) }
        return try currentRoot().appendingPathComponent(path, isDirectory: false)
    }

    func discardIfUnadopted() {
        lock.lock()
        defer { lock.unlock() }
        guard !adopted, let root else { return }
        self.root = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func currentRoot() throws -> URL {
        lock.lock()
        defer { lock.unlock() }
        guard let root else { throw FileBackedStagingError.stagingNotReady }
        return root
    }
}
