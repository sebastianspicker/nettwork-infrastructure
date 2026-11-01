import ContentSafety
import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension ArchiveVerifier {
    public func verifyFileBackedForRestore(
        source: any ArchiveEntrySource, stagingRoot: URL,
        authorization: AuthorizedOperationContext
    ) throws -> FileBackedArchiveRestorePreview {
        let archive = try verifyFileBacked(source: source, stagingRoot: stagingRoot)
        do {
            return try FileBackedArchiveRestorePreview(
                archive: archive,
                approval: ArchiveRestoreApproval.issue(
                    for: archive, authorization: authorization))
        } catch {
            archive.discardIfUnadopted()
            throw error
        }
    }

    /// Copies and hashes every source entry into a fresh private directory.
    /// Payloads are never accumulated in a `[String: Data]` archive image.
    public func verifyFileBacked(
        source: any ArchiveEntrySource,
        stagingRoot: URL
    ) throws -> FileBackedVerifiedArchive {
        defer { (source as? any ArchiveEntrySourceAccessLifetime)?.close() }
        let normalized = try ArchiveEntryValidation.normalize(try source.entries()).sorted { $0.1 < $1.1 }
        try FileBackedStagingFiles.ensurePrivateDirectory(stagingRoot)
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try FileBackedStagingFiles.ensureNewPrivateDirectory(directory)
        do {
            try StagingSweep.markDirectory(directory)
            let entries = try copyEntries(normalized, source: source, destination: directory)
            let digests = Dictionary(uniqueKeysWithValues: entries.map { ($0.metadata.path, $0.digest) })
            let manifest = try validateFileBackedArchive(directory: directory, entries: entries, digests: digests)
            let root = Self.rootDigest(for: digests)
            guard root == manifest.rootSHA256 else { throw ArchiveValidationError.completionMarkerMismatch }
            return FileBackedVerifiedArchive(
                manifest: manifest, rootSHA256: root, entries: entries,
                storage: FileBackedVerifiedArchiveStorage(root: directory))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func copyEntries(
        _ entries: [(ArchiveEntryMetadata, String)],
        source: any ArchiveEntrySource,
        destination: URL
    ) throws -> [FileBackedVerifiedArchiveEntry] {
        var result: [FileBackedVerifiedArchiveEntry] = []
        for (metadata, path) in entries {
            try Task.checkCancellation()
            let url = destination.appendingPathComponent(path, isDirectory: metadata.kind == .directory)
            if metadata.kind == .directory {
                try FileBackedStagingFiles.ensurePrivateDirectory(url)
                continue
            }
            try FileBackedStagingFiles.ensurePrivateDirectory(url.deletingLastPathComponent())
            let digest = try copyEntry(metadata, path: path, source: source, destination: url)
            result.append(
                .init(
                    metadata: .init(
                        path: path, kind: .regularFile,
                        uncompressedSize: digest.size, compressedSize: digest.size),
                    digest: digest))
        }
        return result
    }

    private func copyEntry(
        _ entry: ArchiveEntryMetadata,
        path: String,
        source: any ArchiveEntrySource,
        destination: URL
    ) throws -> ArchiveDigest {
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw FileBackedStagingError.invalidArchiveEntry
        }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: destination.path)
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }
        let reader = try source.reader(for: entry)
        var size = 0
        var hasher = SHA256()
        while let chunk = try reader.nextChunk() {
            try Task.checkCancellation()
            guard !chunk.isEmpty, chunk.count <= entry.uncompressedSize - size else {
                throw ArchiveValidationError.sizeMismatch(path)
            }
            var offset = 0
            while offset < chunk.count {
                try Task.checkCancellation()
                let end = min(offset + 64 * 1_024, chunk.count)
                let fixedChunk = chunk.subdata(in: offset..<end)
                try writer.write(contentsOf: fixedChunk)
                hasher.update(data: fixedChunk)
                offset = end
            }
            size += chunk.count
        }
        guard size == entry.uncompressedSize else { throw ArchiveValidationError.sizeMismatch(path) }
        try writer.synchronize()
        return ArchiveDigest(size: size, sha256: HexDigest.string(hasher.finalize()))
    }

    private func validateFileBackedArchive(
        directory: URL,
        entries: [FileBackedVerifiedArchiveEntry],
        digests: [String: ArchiveDigest]
    ) throws -> ArchiveManifest {
        let manifest = try decodedManifest(in: directory)
        let marker = try decodedCompletionMarker(in: directory)
        try validateFileBackedManifestHeader(manifest, marker: marker, digests: digests)
        let verifiedAudit = try verifiedAudit(in: directory)
        guard manifest.auditRecordCount >= 0, manifest.auditRecordCount <= WorkspaceTransferLimits.maximumRows,
            try recordCount(in: directory) == ArchiveManifestRecordCounts.total(manifest.recordCounts),
            verifiedAudit.count == manifest.auditRecordCount,
            verifiedAudit.headSHA256 == manifest.auditHeadSHA256
        else { throw ArchiveValidationError.manifestMismatch }
        try validateFileBackedAssets(manifest.assets, entries: entries, digests: digests)
        return manifest
    }

    private func decodedManifest(in directory: URL) throws -> ArchiveManifest {
        let data = try readRequiredEntry(ArchiveLayout.manifestPath, in: directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(ArchiveManifest.self, from: data) else {
            throw ArchiveValidationError.archiveDecodeFailed("manifest")
        }
        return value
    }

    private func decodedCompletionMarker(in directory: URL) throws -> ArchiveCompletionMarker {
        let data = try readRequiredEntry(ArchiveLayout.completionPath, in: directory)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(ArchiveCompletionMarker.self, from: data) else {
            throw ArchiveValidationError.archiveDecodeFailed("completion marker")
        }
        return value
    }

    private func verifiedAudit(in directory: URL) throws -> (count: Int, headSHA256: String) {
        try ArchiveAuditChain.verify(readRequiredEntry(ArchiveLayout.auditPath, in: directory))
    }

    private func recordCount(in directory: URL) throws -> Int {
        try ArchiveEntryValidation.countJSONL(readRequiredEntry(ArchiveLayout.recordsPath, in: directory))
    }

    private func readRequiredEntry(_ path: String, in directory: URL) throws -> Data {
        try Task.checkCancellation()
        return try FileBackedStagingFiles.readPrivate(
            directory.appendingPathComponent(path), maximumBytes: ArchiveSafetyLimits.maximumEntryBytes)
    }

    private func validateFileBackedManifestHeader(
        _ manifest: ArchiveManifest,
        marker: ArchiveCompletionMarker,
        digests: [String: ArchiveDigest]
    ) throws {
        guard manifest.schemaVersion == ArchiveManifest.currentSchemaVersion else {
            throw ArchiveValidationError.unsupportedSchemaVersion
        }
        guard manifest.compatibility.supports(readerVersion: readerVersion),
            manifest.workspaceID == manifest.provenance.workspaceID
        else { throw ArchiveValidationError.incompatibleReader }
        guard marker.schemaVersion == manifest.schemaVersion,
            marker.rootSHA256 == manifest.rootSHA256,
            marker.manifestCommitmentSHA256 == (try ArchiveManifestCommitment.digest(for: manifest))
        else { throw ArchiveValidationError.completionMarkerMismatch }
        guard digests[ArchiveLayout.recordsPath]?.sha256 == manifest.recordsSHA256,
            digests[ArchiveLayout.auditPath]?.sha256 == manifest.auditSHA256
        else { throw ArchiveValidationError.hashMismatch("records or audit") }
    }

    private func validateFileBackedAssets(
        _ assets: [ArchiveAsset],
        entries: [FileBackedVerifiedArchiveEntry],
        digests: [String: ArchiveDigest]
    ) throws {
        let actualPaths = Set(entries.map(\.metadata.path).filter { $0.hasPrefix(ArchiveLayout.assetsDirectory + "/") })
        var paths = Set<String>()
        var collisionKeys = Set<String>()
        var ids = Set<ObjectID>()
        for asset in assets {
            let path = try ArchivePathPolicy.normalized(asset.relativePath)
            guard path.hasPrefix(ArchiveLayout.assetsDirectory + "/"), paths.insert(path).inserted,
                collisionKeys.insert(ArchivePathPolicy.collisionKey(path)).inserted,
                ids.insert(asset.id).inserted, asset.stableID == ArchiveAsset.stableID(for: path),
                !asset.contentType.isEmpty, asset.byteCount >= 0,
                digests[path] == ArchiveDigest(size: asset.byteCount, sha256: asset.sha256)
            else { throw ArchiveValidationError.manifestMismatch }
        }
        guard paths == actualPaths else { throw ArchiveValidationError.manifestMismatch }
    }
}
