import CloudSync
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Durable, single-writer stand-in for the server side of a workspace, rooted
/// at an injected directory. It keeps the full record state the local transport
/// needs (tombstones, opaque system fields, change tags), a revision that grows
/// by one per commit with the revision each record last changed at, and a random
/// incarnation created once so a foreign or reset store is detectable.
///
/// Every commit applies all writes in memory first, then persists one complete
/// binary-plist snapshot by atomic replace. Asset bytes are content-addressed
/// under `assets/` and are written and verified before the snapshot that
/// references them, so a crash leaves at most unreferenced assets (never
/// collected). Loading is lazy and fails closed: an unknown version, undecodable
/// file, oversized snapshot or missing asset throws and is never treated as empty.
// shortcut: every commit rewrites the whole snapshot and tombstones are kept, capped at
// 64 MiB (then commits fail as quota exceeded); move to an append log before stage-1 data nears that size.
public actor LocalWorkspaceRecordStore {
    private struct State {
        var incarnation: UUID
        var revision: UInt64
        var records: [String: LocalStoredRecord]

        var snapshot: LocalWorkspaceRecordSnapshot {
            LocalWorkspaceRecordSnapshot(incarnation: incarnation, revision: revision, records: Array(records.values))
        }
    }

    private let files: LocalWorkspaceRecordStoreFiles
    private var loaded: State?

    public init(directory: URL, writer: any LocalWorkspaceRecordStoreFileWriting = AtomicLocalFileWriter()) {
        self.files = LocalWorkspaceRecordStoreFiles(directory: directory, writer: writer)
    }

    public func snapshot() throws -> LocalWorkspaceRecordSnapshot { try state().snapshot }
    public func incarnation() throws -> UUID { try state().incarnation }
    public func currentRevision() throws -> UInt64 { try state().revision }
    public func record(named recordName: String) throws -> LocalStoredRecord? { try state().records[recordName] }

    public func record(for resourceKey: ResourceKey, workspaceID: ObjectID) throws -> LocalStoredRecord? {
        try record(named: CloudRecordNaming.recordName(for: resourceKey, workspaceID: workspaceID))
    }

    /// Every record (tombstones included) last changed after `revision`, oldest change first.
    public func changes(since revision: UInt64) throws -> [LocalStoredRecord] {
        try state().records.values.filter { $0.changedAtRevision > revision }
            .sorted { ($0.changedAtRevision, $0.recordName) < ($1.changedAtRevision, $1.recordName) }
    }

    /// Verified bytes of a stored asset; throws if the file is missing or does not match its digest.
    public func assetBytes(for asset: CloudRecordAssetMetadata) throws -> Data {
        try files.readAsset(sha256: asset.sha256, byteCount: asset.byteCount)
    }

    /// Applies every write or none. On any failure the in-memory and on-disk state are unchanged.
    @discardableResult
    public func commit(_ mutation: LocalWorkspaceMutation) throws -> LocalWorkspaceCommit {
        var next = try state()
        if let expected = mutation.expectedRevision, expected != next.revision {
            throw LocalWorkspaceRecordStoreError.revisionConflict(expected: expected, actual: next.revision)
        }
        try Self.validate(mutation.writes)
        guard next.revision < UInt64.max else { throw LocalWorkspaceRecordStoreError.revisionOverflow }
        next.revision += 1
        var stamped: [LocalStoredRecord] = []
        for write in mutation.writes {
            if let bytes = write.assetBytes, let asset = write.record.asset { try files.storeAsset(bytes, sha256: asset.sha256) }
            let record = write.record.stamped(at: next.revision)
            next.records[record.recordName] = record
            stamped.append(record)
        }
        try files.persist(next.snapshot)
        loaded = next
        return LocalWorkspaceCommit(revision: next.revision, records: stamped)
    }

    /// Commits `writes` only while the store has never held a record. Returns whether it seeded.
    @discardableResult
    public func seedIfEmpty(_ writes: [LocalRecordWrite]) throws -> Bool {
        let current = try state()
        guard current.revision == 0, current.records.isEmpty else { return false }
        try commit(LocalWorkspaceMutation(writes: writes, expectedRevision: 0))
        return true
    }

    /// Seeds the empty-workspace bootstrap sentinel (`lifecycle: .empty(epoch: 0)`) for a fresh store.
    /// Its system fields are an opaque local marker bound to the change tag.
    @discardableResult
    public func seedBootstrapSentinel(for zone: AuthoritativeWorkspaceZone, at date: Date = Date()) throws -> Bool {
        let workspace = CloudWorkspaceRecord(
            workspaceID: zone.workspaceID, zoneName: zone.zoneName, zoneOwnerRecordName: zone.zoneOwnerRecordName, lifecycle: .empty(epoch: 0))
        let changeTag = UUID().uuidString.lowercased()
        let record = LocalStoredRecord(
            resourceKey: AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: zone.workspaceID), workspaceID: zone.workspaceID,
            recordType: CloudRecordNaming.workspaceRecordType, schemaVersion: CloudRecordNaming.schemaVersion,
            payload: try CloudDeterministicCoding.encode(workspace), systemFields: Data("local-system-fields:\(changeTag)".utf8),
            changeTag: changeTag, serverModifiedAt: Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded(.down) / 1_000))
        return try seedIfEmpty([LocalRecordWrite(record: record)])
    }

    private func state() throws -> State {
        if let loaded { return loaded }
        let state: State
        if let snapshot = try files.loadSnapshot() {
            state = try validated(snapshot)
        } else {
            state = State(incarnation: UUID(), revision: 0, records: [:])
            try files.persist(state.snapshot)
        }
        loaded = state
        return state
    }

    private func validated(_ snapshot: LocalWorkspaceRecordSnapshot) throws -> State {
        guard snapshot.formatVersion == LocalWorkspaceRecordSnapshot.currentFormatVersion else {
            throw LocalWorkspaceRecordStoreError.unsupportedFormatVersion(snapshot.formatVersion)
        }
        var records: [String: LocalStoredRecord] = [:]
        for record in snapshot.records {
            guard records.updateValue(record, forKey: record.recordName) == nil, record.changedAtRevision <= snapshot.revision else {
                throw LocalWorkspaceRecordStoreError.corruptSnapshot
            }
            if let asset = record.asset, try !files.assetExists(sha256: asset.sha256, byteCount: asset.byteCount) {
                throw LocalWorkspaceRecordStoreError.assetMissing(sha256: asset.sha256)
            }
        }
        return State(incarnation: snapshot.incarnation, revision: snapshot.revision, records: records)
    }

    private static func validate(_ writes: [LocalRecordWrite]) throws {
        guard !writes.isEmpty else { throw LocalWorkspaceRecordStoreError.emptyMutation }
        var names: Set<String> = []
        for write in writes {
            let name = write.record.recordName
            guard names.insert(name).inserted else { throw LocalWorkspaceRecordStoreError.duplicateRecord(recordName: name) }
            try validateAsset(of: write)
        }
    }

    private static func validateAsset(of write: LocalRecordWrite) throws {
        switch (write.record.asset, write.assetBytes) {
        case (nil, nil): return
        case let (asset?, bytes?):
            guard bytes.count == asset.byteCount, CloudRecordAssetDescriptor.sha256(for: bytes) == asset.sha256 else {
                throw LocalWorkspaceRecordStoreError.assetIntegrityFailure(sha256: asset.sha256)
            }
        default: throw LocalWorkspaceRecordStoreError.invalidRecord(recordName: write.record.recordName)
        }
    }
}
