import ContentSafety
import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public struct ArchiveVerifier: Sendable {
    public let readerVersion: Int
    public init(readerVersion: Int = ArchiveManifest.currentSchemaVersion) { self.readerVersion = readerVersion }

    public func verifyForRestore(
        source: any ArchiveEntrySource, authorization: AuthorizedOperationContext
    ) throws -> ArchiveRestorePreview {
        let archive = try verify(source: source)
        return try ArchiveRestorePreview(
            archive: archive,
            approval: ArchiveRestoreApproval.issue(for: archive, authorization: authorization))
    }

    public func verify(source: any ArchiveEntrySource) throws -> VerifiedArchive {
        let normalizedEntries = try normalize(try source.entries())
        let streamed = try readPayloads(normalizedEntries, source: source)
        let decoded = try decodeArchive(payloads: streamed.payloads)
        try validateManifest(decoded, digests: streamed.digests)
        let assetPayloads = streamed.payloads.filter {
            $0.key.hasPrefix(ArchiveLayout.assetsDirectory + "/")
        }
        try validateAssets(decoded.manifest.assets, payloads: assetPayloads, digests: streamed.digests)
        let root = Self.rootDigest(for: streamed.digests)
        guard root == decoded.manifest.rootSHA256,
            decoded.marker.schemaVersion == decoded.manifest.schemaVersion,
            decoded.marker.rootSHA256 == root
        else {
            throw ArchiveValidationError.completionMarkerMismatch
        }
        return VerifiedArchive(
            manifest: decoded.manifest, recordsJSONL: decoded.records,
            auditJSONL: decoded.audit, assets: assetPayloads, rootSHA256: root)
    }

    private func normalize(
        _ entries: [ArchiveEntryMetadata]
    ) throws -> [(entry: ArchiveEntryMetadata, path: String)] {
        guard entries.count <= ArchiveSafetyLimits.maximumEntries else {
            throw ArchiveValidationError.archiveTooLarge
        }
        var seen = Set<String>()
        var normalized: [(ArchiveEntryMetadata, String)] = []
        var declaredTotal = 0
        for entry in entries {
            let path = try ArchivePathPolicy.normalized(entry.path)
            guard seen.insert(ArchivePathPolicy.collisionKey(path)).inserted else {
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

    private func validateKind(_ kind: ArchiveEntryKind, path: String) throws {
        guard !ArchivePathPolicy.isAllowed(path, kind: kind) else { return }
        if kind != .regularFile && kind != .directory {
            throw ArchiveValidationError.forbiddenEntryKind(path)
        }
        throw ArchiveValidationError.unknownEntry(path)
    }

    private func validateSizes(_ entry: ArchiveEntryMetadata, path: String) throws {
        guard entry.uncompressedSize >= 0 else {
            throw ArchiveValidationError.invalidEntryMetadata(path)
        }
        guard entry.compressedSize >= 0 else {
            throw ArchiveValidationError.invalidEntryMetadata(path)
        }
        guard entry.uncompressedSize <= ArchiveSafetyLimits.maximumEntryBytes else {
            throw ArchiveValidationError.invalidEntryMetadata(path)
        }
        guard entry.uncompressedSize > 0 else { return }
        guard entry.compressedSize > 0 else {
            throw ArchiveValidationError.invalidEntryMetadata(path)
        }
        guard entry.compressedSize <= Int.max / ArchiveSafetyLimits.maximumExpansionRatio else {
            throw ArchiveValidationError.invalidEntryMetadata(path)
        }
        guard entry.uncompressedSize <= entry.compressedSize * ArchiveSafetyLimits.maximumExpansionRatio else {
            throw ArchiveValidationError.expansionLimitExceeded
        }
    }

    private func readPayloads(
        _ entries: [(entry: ArchiveEntryMetadata, path: String)],
        source: any ArchiveEntrySource
    ) throws -> (payloads: [String: Data], digests: [String: ArchiveDigest]) {
        var payloads: [String: Data] = [:]
        var digests: [String: ArchiveDigest] = [:]
        for item in entries where item.entry.kind == .regularFile {
            let value = try stream(entry: item.entry, path: item.path, source: source)
            payloads[item.path] = value.data
            digests[item.path] = ArchiveDigest(size: value.size, sha256: value.sha256)
        }
        return (payloads, digests)
    }

    private func decodeArchive(payloads: [String: Data]) throws -> DecodedArchive {
        guard let manifestData = payloads[ArchiveLayout.manifestPath],
            let records = payloads[ArchiveLayout.recordsPath],
            let audit = payloads[ArchiveLayout.auditPath],
            let completionData = payloads[ArchiveLayout.completionPath]
        else {
            throw ArchiveValidationError.manifestMismatch
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let manifest = try? decoder.decode(ArchiveManifest.self, from: manifestData),
            let marker = try? decoder.decode(ArchiveCompletionMarker.self, from: completionData)
        else {
            throw ArchiveValidationError.archiveDecodeFailed("manifest or completion marker")
        }
        return DecodedArchive(manifest: manifest, marker: marker, records: records, audit: audit)
    }

    private func validateManifest(_ archive: DecodedArchive, digests: [String: ArchiveDigest]) throws {
        let manifest = archive.manifest
        guard manifest.schemaVersion == ArchiveManifest.currentSchemaVersion else {
            throw ArchiveValidationError.unsupportedSchemaVersion
        }
        guard manifest.compatibility.supports(readerVersion: readerVersion),
            manifest.workspaceID == manifest.provenance.workspaceID
        else {
            throw ArchiveValidationError.incompatibleReader
        }
        guard archive.marker.manifestCommitmentSHA256 == (try ArchiveManifestCommitment.digest(for: manifest)) else {
            throw ArchiveValidationError.completionMarkerMismatch
        }
        guard digests[ArchiveLayout.recordsPath]?.sha256 == manifest.recordsSHA256,
            digests[ArchiveLayout.auditPath]?.sha256 == manifest.auditSHA256
        else {
            throw ArchiveValidationError.hashMismatch("records or audit")
        }
        let verifiedAudit = try ArchiveAuditChain.verify(archive.audit)
        let recordCount = try ArchiveManifestRecordCounts.total(manifest.recordCounts)
        guard manifest.auditRecordCount >= 0,
            manifest.auditRecordCount <= WorkspaceTransferLimits.maximumRows,
            try jsonlCount(archive.records) == recordCount,
            verifiedAudit.count == manifest.auditRecordCount,
            verifiedAudit.headSHA256 == manifest.auditHeadSHA256
        else {
            throw ArchiveValidationError.manifestMismatch
        }
    }

    private func validateAssets(
        _ assets: [ArchiveAsset], payloads: [String: Data],
        digests: [String: ArchiveDigest]
    ) throws {
        guard payloads.count == assets.count else { throw ArchiveValidationError.manifestMismatch }
        var declaredAssetPaths = Set<String>()
        var declaredAssetCollisionKeys = Set<String>()
        var declaredAssetIDs = Set<ObjectID>()
        for asset in assets {
            let path = try ArchivePathPolicy.normalized(asset.relativePath)
            try validateAsset(
                asset, path: path, digests: digests, paths: &declaredAssetPaths,
                collisionKeys: &declaredAssetCollisionKeys, ids: &declaredAssetIDs)
        }
        guard declaredAssetPaths == Set(payloads.keys) else {
            throw ArchiveValidationError.manifestMismatch
        }
    }

    private func validateAsset(
        _ asset: ArchiveAsset, path: String, digests: [String: ArchiveDigest],
        paths: inout Set<String>, collisionKeys: inout Set<String>, ids: inout Set<ObjectID>
    ) throws {
        try validateAssetIdentity(
            asset, path: path, paths: &paths, collisionKeys: &collisionKeys, ids: &ids
        )
        try validateAssetMetadata(asset, path: path, digests: digests)
    }

    private func validateAssetIdentity(
        _ asset: ArchiveAsset, path: String, paths: inout Set<String>,
        collisionKeys: inout Set<String>, ids: inout Set<ObjectID>
    ) throws {
        guard path.hasPrefix(ArchiveLayout.assetsDirectory + "/") else {
            throw ArchiveValidationError.manifestMismatch
        }
        guard paths.insert(path).inserted else { throw ArchiveValidationError.manifestMismatch }
        guard collisionKeys.insert(ArchivePathPolicy.collisionKey(path)).inserted else {
            throw ArchiveValidationError.manifestMismatch
        }
        guard ids.insert(asset.id).inserted else { throw ArchiveValidationError.manifestMismatch }
    }

    private func validateAssetMetadata(
        _ asset: ArchiveAsset, path: String, digests: [String: ArchiveDigest]
    ) throws {
        guard asset.stableID == ArchiveAsset.stableID(for: path) else {
            throw ArchiveValidationError.manifestMismatch
        }
        guard !asset.contentType.isEmpty else { throw ArchiveValidationError.manifestMismatch }
        guard asset.byteCount >= 0 else { throw ArchiveValidationError.manifestMismatch }
        guard let digest = digests[path] else { throw ArchiveValidationError.manifestMismatch }
        guard digest.sha256 == asset.sha256 else { throw ArchiveValidationError.manifestMismatch }
        guard digest.size == asset.byteCount else { throw ArchiveValidationError.manifestMismatch }
    }

    public static func rootDigest(for entries: [String: ArchiveDigest]) -> String {
        var hasher = SHA256()
        for path in entries.keys.filter({ $0 != ArchiveLayout.manifestPath && $0 != ArchiveLayout.completionPath }).sorted() {
            guard let digest = entries[path] else { continue }
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(digest.sha256.utf8))
            var size = UInt64(digest.size).bigEndian
            withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }
        }
        return HexDigest.string(hasher.finalize())
    }

    private func stream(entry: ArchiveEntryMetadata, path: String, source: any ArchiveEntrySource) throws -> (data: Data, size: Int, sha256: String) {
        let reader = try source.reader(for: entry)
        var body = Data(), hasher = SHA256()
        while let chunk = try reader.nextChunk() {
            guard !chunk.isEmpty else { throw ArchiveValidationError.sizeMismatch(path) }
            body.append(chunk)
            guard body.count <= entry.uncompressedSize, body.count <= ArchiveSafetyLimits.maximumEntryBytes else {
                throw ArchiveValidationError.sizeMismatch(path)
            }
            hasher.update(data: chunk)
        }
        guard body.count == entry.uncompressedSize else { throw ArchiveValidationError.sizeMismatch(path) }
        return (body, body.count, HexDigest.string(hasher.finalize()))
    }

    private func jsonlCount(_ data: Data) throws -> Int {
        var count = 0
        var hasRecordBytes = false
        for byte in data {
            if byte == 0x0A {
                if hasRecordBytes {
                    let (nextCount, overflow) = count.addingReportingOverflow(1)
                    guard !overflow, nextCount <= WorkspaceTransferLimits.maximumRows else {
                        throw ArchiveValidationError.manifestMismatch
                    }
                    count = nextCount
                }
                hasRecordBytes = false
            } else {
                hasRecordBytes = true
            }
        }
        if hasRecordBytes {
            let (nextCount, overflow) = count.addingReportingOverflow(1)
            guard !overflow, nextCount <= WorkspaceTransferLimits.maximumRows else {
                throw ArchiveValidationError.manifestMismatch
            }
            count = nextCount
        }
        return count
    }

    private var requiredPaths: [String] {
        [
            ArchiveLayout.manifestPath, ArchiveLayout.recordsPath, ArchiveLayout.auditPath,
            ArchiveLayout.completionPath,
        ]
    }

    private struct DecodedArchive {
        let manifest: ArchiveManifest
        let marker: ArchiveCompletionMarker
        let records: Data
        let audit: Data
    }
}

/// The restore adapter authenticates a brand-new target and keeps staging invisible until one final CAS.
