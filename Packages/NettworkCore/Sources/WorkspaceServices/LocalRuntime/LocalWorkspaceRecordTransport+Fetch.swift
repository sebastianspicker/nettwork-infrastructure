import CloudSync
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension LocalWorkspaceRecordTransport {
    /// Every change after the persisted token, oldest revision first. Tombstones
    /// are `isDeleted` envelopes and assets travel inline. A batch always ends on
    /// a whole store revision within the adapter limits, and its token names the
    /// last included revision, so a cut-off batch resumes exactly on the next fetch.
    func changeBatch(after persistedState: Data?) async throws -> CloudChangeBatch {
        let incarnation = try await store.incarnation()
        let revision = try await store.currentRevision()
        let since = try startRevision(persistedState, incarnation: incarnation, currentRevision: revision)
        let changes = try await store.changes(since: since).filter { $0.changedAtRevision <= revision }
        var records: [CloudRecordEnvelope] = []
        var byteCount = 0
        var lastIncluded = since
        for group in Self.revisionGroups(changes) {
            var envelopes: [CloudRecordEnvelope] = []
            for record in group.records { envelopes.append(try await envelope(for: record)) }
            let groupBytes = envelopes.reduce(0) { $0 + Self.byteCount(of: $1) }
            guard records.count + envelopes.count <= Self.maximumBatchRecords, byteCount + groupBytes <= Self.maximumBatchBytes else {
                guard !records.isEmpty else { throw LocalWorkspaceRecordTransportError.changeBatchTooLarge }
                return try batch(records, incarnation: incarnation, revision: lastIncluded)
            }
            records.append(contentsOf: envelopes)
            byteCount += groupBytes
            lastIncluded = group.revision
        }
        return try batch(records, incarnation: incarnation, revision: revision)
    }

    /// A missing token starts from the beginning of this store; any other token must be this store's own.
    private func startRevision(_ persistedState: Data?, incarnation: UUID, currentRevision: UInt64) throws -> UInt64 {
        guard let persistedState else { return 0 }
        let token = try LocalWorkspaceChangeToken.decode(persistedState)
        guard token.incarnation == incarnation, token.workspaceID == workspaceZone.workspaceID, token.revision <= currentRevision else {
            throw LocalWorkspaceRecordTransportError.foreignChangeToken
        }
        return token.revision
    }

    private func batch(_ records: [CloudRecordEnvelope], incarnation: UUID, revision: UInt64) throws -> CloudChangeBatch {
        let token = LocalWorkspaceChangeToken(incarnation: incarnation, workspaceID: workspaceZone.workspaceID, revision: revision)
        return CloudChangeBatch(records: records, newState: try token.encoded())
    }

    private func envelope(for record: LocalStoredRecord) async throws -> CloudRecordEnvelope {
        guard record.workspaceID == workspaceZone.workspaceID else { throw LocalWorkspaceRecordTransportError.malformedStoredRecord(record.resourceKey) }
        var asset: CloudRecordAssetDescriptor?
        if let metadata = record.asset {
            asset = try CloudRecordAssetDescriptor(metadata: metadata, storage: .inline(try await store.assetBytes(for: metadata)))
        }
        return CloudRecordEnvelope(
            resourceKey: record.resourceKey, workspaceID: record.workspaceID, recordType: record.recordType, schemaVersion: record.schemaVersion,
            payload: record.payload, recordAsset: asset, visibility: record.visibility, systemFields: record.systemFields, changeTag: record.changeTag,
            isDeleted: record.isDeleted)
    }

    private static func byteCount(of envelope: CloudRecordEnvelope) -> Int {
        envelope.payload.count + envelope.systemFields.count + (envelope.recordAsset?.byteCount ?? 0)
    }

    private static func revisionGroups(_ changes: [LocalStoredRecord]) -> [(revision: UInt64, records: [LocalStoredRecord])] {
        var groups: [(revision: UInt64, records: [LocalStoredRecord])] = []
        for record in changes {
            if let last = groups.indices.last, groups[last].revision == record.changedAtRevision {
                groups[last].records.append(record)
            } else {
                groups.append((record.changedAtRevision, [record]))
            }
        }
        return groups
    }
}
