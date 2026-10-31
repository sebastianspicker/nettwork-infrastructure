import CloudSync
import Foundation
import NetworkModel
import WorkspaceChangeControl

extension LocalWorkspaceRecordTransport {
    /// Opaque system fields of a local record, bound to its change tag (the format the store's sentinel seed uses).
    static func systemFields(forChangeTag changeTag: String) -> Data { Data("local-system-fields:\(changeTag)".utf8) }

    /// The shared commit core of `saveAtomically` and `saveConditionally`. The
    /// mutation must already be validated and in the served zone. Preconditions
    /// are evaluated against one store revision and the commit is bound to it,
    /// so an interleaved commit forces a fresh evaluation instead of a blind write.
    func commit(_ mutation: AtomicCloudMutation) async throws -> LocalCommitOutcome {
        var attempt = 1
        while true {
            let revision = try await store.currentRevision()
            let stored = try await storedRecords(for: mutation)
            if let conflict = Self.firstUnmetPrecondition(in: mutation, stored: stored) { return conflict }
            let writes = try await writes(for: mutation, stored: stored)
            do {
                try await store.commit(LocalWorkspaceMutation(writes: writes, expectedRevision: revision))
            } catch LocalWorkspaceRecordStoreError.revisionConflict where attempt < Self.maximumCommitAttempts {
                attempt += 1
                continue
            }
            if shouldReportIndeterminate(after: mutation) { throw LocalSimulatedIndeterminateCommit() }
            return .committed
        }
    }

    private func storedRecords(for mutation: AtomicCloudMutation) async throws -> [String: LocalStoredRecord] {
        var stored: [String: LocalStoredRecord] = [:]
        for envelope in mutation.records {
            guard let record = try await store.record(named: envelope.recordName) else { continue }
            guard record.resourceKey == envelope.resourceKey, record.workspaceID == envelope.workspaceID else {
                throw LocalWorkspaceRecordTransportError.malformedStoredRecord(envelope.resourceKey)
            }
            stored[envelope.recordName] = record
        }
        return stored
    }

    /// `mustNotExist` fails on any stored record, tombstones included; `exact`
    /// requires both the system fields and the change tag to match.
    private static func firstUnmetPrecondition(in mutation: AtomicCloudMutation, stored: [String: LocalStoredRecord]) -> LocalCommitOutcome? {
        let preconditions = Dictionary(mutation.preconditions.map { ($0.preconditionRecordName, $0) }, uniquingKeysWith: { first, _ in first })
        for envelope in mutation.records {
            let current = stored[envelope.recordName]
            switch preconditions[envelope.recordName] {
            case .mustNotExist?:
                if current != nil { return .conflict(envelope: envelope, stored: current) }
            case let .exact(_, systemFields, changeTag)?:
                guard let current, current.systemFields == systemFields, current.changeTag == changeTag else {
                    return .conflict(envelope: envelope, stored: current)
                }
            case nil:
                return .conflict(envelope: envelope, stored: current)
            }
        }
        return nil
    }

    private func writes(for mutation: AtomicCloudMutation, stored: [String: LocalStoredRecord]) async throws -> [LocalRecordWrite] {
        let serverModifiedAt = Self.millisecondTruncated(now())
        var writes: [LocalRecordWrite] = []
        writes.reserveCapacity(mutation.records.count)
        for envelope in mutation.records {
            let changeTag = UUID().uuidString.lowercased()
            switch envelope.writeMode {
            case .businessSave:
                writes.append(try Self.businessWrite(envelope, changeTag: changeTag, at: serverModifiedAt))
            case .assertionPreserving:
                guard let current = stored[envelope.recordName] else { throw LocalWorkspaceRecordTransportError.assertionMismatch(envelope.resourceKey) }
                writes.append(try await assertionWrite(envelope, current: current, changeTag: changeTag, at: serverModifiedAt))
            }
        }
        return writes
    }

    /// A business save writes the envelope's fields; a nil asset clears any previous one.
    private static func businessWrite(_ envelope: CloudRecordEnvelope, changeTag: String, at serverModifiedAt: Date) throws -> LocalRecordWrite {
        let record = LocalStoredRecord(
            resourceKey: envelope.resourceKey, workspaceID: envelope.workspaceID, recordType: envelope.recordType, schemaVersion: envelope.schemaVersion,
            payload: envelope.payload, visibility: envelope.visibility, asset: envelope.recordAsset?.metadata, isDeleted: envelope.isDeleted,
            systemFields: systemFields(forChangeTag: changeTag), changeTag: changeTag, serverModifiedAt: serverModifiedAt)
        return LocalRecordWrite(record: record, assetBytes: try envelope.recordAsset?.validatedBytes())
    }

    /// A read assertion keeps the stored record, which must equal what was asserted,
    /// but still receives a new change tag so later writers conditioned on it are fenced.
    private func assertionWrite(_ envelope: CloudRecordEnvelope, current: LocalStoredRecord, changeTag: String, at serverModifiedAt: Date) async throws
        -> LocalRecordWrite
    {
        guard current.recordType == envelope.recordType, current.schemaVersion == envelope.schemaVersion, current.payload == envelope.payload,
            current.visibility == envelope.visibility, current.isDeleted == envelope.isDeleted
        else { throw LocalWorkspaceRecordTransportError.assertionMismatch(envelope.resourceKey) }
        let record = LocalStoredRecord(
            resourceKey: current.resourceKey, workspaceID: current.workspaceID, recordType: current.recordType, schemaVersion: current.schemaVersion,
            payload: current.payload, visibility: current.visibility, asset: current.asset, isDeleted: current.isDeleted,
            systemFields: Self.systemFields(forChangeTag: changeTag), changeTag: changeTag, serverModifiedAt: serverModifiedAt)
        let assetBytes: Data?
        if let asset = current.asset { assetBytes = try await store.assetBytes(for: asset) } else { assetBytes = nil }
        return LocalRecordWrite(record: record, assetBytes: assetBytes)
    }

    static func millisecondTruncated(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded(.down) / 1_000)
    }

    /// Scoped to every record of the batch, as the repository's conflict-scope check requires.
    func reconciliationCase(for mutation: AtomicCloudMutation, conflicting envelope: CloudRecordEnvelope, stored: LocalStoredRecord?) -> ReconciliationCase {
        var base: [ResourceKey: ReconciliationSnapshot] = [:]
        var intended: [ResourceKey: ReconciliationSnapshot] = [:]
        for record in mutation.records {
            intended[record.resourceKey] = Self.snapshot(of: record)
            let precondition = mutation.preconditions.first { $0.preconditionRecordName == record.recordName }
            guard case let .exact(_, systemFields, changeTag)? = precondition else { continue }
            base[record.resourceKey] = ReconciliationSnapshot(
                resourceKey: record.resourceKey, recordType: record.recordType, schemaVersion: record.schemaVersion, encodedRecord: nil,
                systemFields: systemFields, changeTag: changeTag, isTombstone: false)
        }
        let current = stored.map { [envelope.resourceKey: Self.snapshot(of: $0)] } ?? [:]
        return ReconciliationCase(
            namespace: account.namespace, operationID: mutation.operationID, resourceKeys: Set(mutation.records.map(\.resourceKey)),
            reason: .serverRecordChanged, base: base, intended: intended, current: current, detectedAt: now())
    }

    private static func snapshot(of envelope: CloudRecordEnvelope) -> ReconciliationSnapshot {
        ReconciliationSnapshot(
            resourceKey: envelope.resourceKey, recordType: envelope.recordType, schemaVersion: envelope.schemaVersion, encodedRecord: envelope.payload,
            systemFields: envelope.systemFields, changeTag: envelope.changeTag, isTombstone: envelope.isDeleted)
    }

    private static func snapshot(of record: LocalStoredRecord) -> ReconciliationSnapshot {
        ReconciliationSnapshot(
            resourceKey: record.resourceKey, recordType: record.recordType, schemaVersion: record.schemaVersion, encodedRecord: record.payload,
            systemFields: record.systemFields, changeTag: record.changeTag, isTombstone: record.isDeleted)
    }
}
