import ContentSafety
import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public struct AuthorizedArchiveExportService: Sendable {
    private let source: any ArchiveExportSource
    private let currentContext: any CurrentAuthorizationContextProviding

    public init(source: any ArchiveExportSource, currentContext: any CurrentAuthorizationContextProviding) {
        self.source = source
        self.currentContext = currentContext
    }

    public func makeDocument(context: AuthorizedOperationContext, createdAt: Date = .now) async throws -> ArchiveExportDocument {
        try await authorize(context)
        let input = try await source.snapshot(for: context.account.namespace)
        try await authorize(context)
        var staged = try stageAssets(input.assets)
        staged.entries[ArchiveLayout.recordsPath] = input.recordsJSONL
        staged.entries[ArchiveLayout.auditPath] = input.auditJSONL
        let verifiedAudit = try validateTransferBodies(input, entries: staged.entries)
        let digests = staged.entries.mapValues {
            ArchiveDigest(size: $0.count, sha256: HexDigest.string(SHA256.hash(data: $0)))
        }
        let assets = try manifestAssets(payloads: staged.payloads, digests: digests)
        let root = ArchiveVerifier.rootDigest(for: digests)
        let manifest = makeManifest(
            input: input, assets: assets, verifiedAudit: verifiedAudit,
            digests: digests, root: root, namespace: context.account.namespace, createdAt: createdAt)
        let marker = ArchiveCompletionMarker(
            rootSHA256: root,
            manifestCommitmentSHA256: try ArchiveManifestCommitment.digest(for: manifest),
            completedAt: createdAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        staged.entries[ArchiveLayout.manifestPath] = try encoder.encode(manifest)
        staged.entries[ArchiveLayout.completionPath] = try encoder.encode(marker)
        return ArchiveExportDocument(manifest: manifest, completionMarker: marker, entries: staged.entries)
    }

    private func stageAssets(
        _ assets: [ArchiveAssetPayload]
    ) throws -> (entries: [String: Data], payloads: [String: ArchiveAssetPayload]) {
        var entries: [String: Data] = [:]
        var pathKeys = Set<String>()
        var assetPayloads: [String: ArchiveAssetPayload] = [:]
        var assetIDs = Set<ObjectID>()
        for payload in assets {
            let path = try ArchivePathPolicy.normalized(payload.relativePath)
            guard path.hasPrefix(ArchiveLayout.assetsDirectory + "/"), path == payload.relativePath,
                payload.stableID == ArchiveAsset.stableID(for: path),
                !payload.contentType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw ArchiveValidationError.invalidPath(payload.relativePath)
            }
            guard pathKeys.insert(ArchivePathPolicy.collisionKey(path)).inserted else { throw ArchiveValidationError.duplicatePath(path) }
            guard assetIDs.insert(payload.id).inserted else { throw ArchiveValidationError.manifestMismatch }
            guard payload.bytes.count <= ArchiveSafetyLimits.maximumEntryBytes else { throw ArchiveValidationError.archiveTooLarge }
            entries[path] = payload.bytes
            assetPayloads[path] = payload
        }
        return (entries, assetPayloads)
    }

    private func validateTransferBodies(
        _ input: ArchiveExportInput, entries: [String: Data]
    ) throws -> (count: Int, headSHA256: String) {
        let verifiedAudit = try ArchiveAuditChain.verify(input.auditJSONL)
        let recordCount = try ArchiveManifestRecordCounts.total(input.recordCounts)
        guard try jsonlCount(input.recordsJSONL) == recordCount,
            verifiedAudit.count <= WorkspaceTransferLimits.maximumRows,
            input.auditHeadSHA256 == verifiedAudit.headSHA256
        else {
            throw ArchiveValidationError.manifestMismatch
        }
        var totalBytes = 0
        for body in entries.values {
            guard body.count <= ArchiveSafetyLimits.maximumEntryBytes, totalBytes <= ArchiveSafetyLimits.maximumExpandedBytes - body.count else {
                throw ArchiveValidationError.archiveTooLarge
            }
            totalBytes += body.count
        }
        return verifiedAudit
    }

    private func manifestAssets(
        payloads: [String: ArchiveAssetPayload], digests: [String: ArchiveDigest]
    ) throws -> [ArchiveAsset] {
        let assets = payloads.keys.sorted().compactMap { path -> ArchiveAsset? in
            guard let payload = payloads[path], let digest = digests[path],
                digest.size == payload.bytes.count,
                digest.sha256 == HexDigest.string(SHA256.hash(data: payload.bytes))
            else {
                return nil
            }
            return ArchiveAsset(
                id: payload.id, relativePath: path, sha256: digest.sha256, size: digest.size, contentType: payload.contentType, stableID: payload.stableID)
        }
        guard assets.count == payloads.count else { throw ArchiveValidationError.manifestMismatch }
        return assets
    }

    private func makeManifest(
        input: ArchiveExportInput, assets: [ArchiveAsset],
        verifiedAudit: (count: Int, headSHA256: String), digests: [String: ArchiveDigest], root: String,
        namespace: PersistenceNamespace, createdAt: Date
    ) -> ArchiveManifest {
        let provenance = ArchiveSourceProvenance(
            workspaceID: namespace.workspaceID, containerIdentifier: namespace.containerIdentifier, zoneName: namespace.zoneName,
            zoneOwnerRecordName: namespace.zoneOwnerRecordName)
        return ArchiveManifest(
            workspaceID: namespace.workspaceID, createdAt: createdAt,
            recordCounts: input.recordCounts, assets: assets, auditRecordCount: verifiedAudit.count,
            provenance: provenance, recordsSHA256: digests[ArchiveLayout.recordsPath]?.sha256 ?? "",
            auditSHA256: digests[ArchiveLayout.auditPath]?.sha256 ?? "",
            auditHeadSHA256: verifiedAudit.headSHA256, rootSHA256: root)
    }

    private func authorize(_ context: AuthorizedOperationContext) async throws {
        guard await currentContext.validateCurrent(context) else {
            throw ImportAuthorizationError.staleContext
        }
        guard context.action == .exportArchive else { throw ImportAuthorizationError.actionMismatch }
        guard context.actor.role == .administrator else { throw ImportAuthorizationError.administratorRequired }
        guard context.account.sharePermission == .owner || context.account.sharePermission == .readWrite else {
            throw ImportAuthorizationError.writePermissionRequired
        }
        guard context.validateCurrent(account: try await source.currentAccount()),
            await currentContext.validateCurrent(context)
        else {
            throw ImportAuthorizationError.staleContext
        }
    }

    private func jsonlCount(_ data: Data) throws -> Int {
        var count = 0
        for byte in data where byte == 0x0A {
            let (nextCount, overflow) = count.addingReportingOverflow(1)
            guard !overflow, nextCount <= WorkspaceTransferLimits.maximumRows else {
                throw ArchiveValidationError.manifestMismatch
            }
            count = nextCount
        }
        return count
    }
}
