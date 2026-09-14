import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension CompositeCloudRemoteReferenceValidator {
    public func validate(candidate: [VerifiedCloudRecord], against snapshot: CloudRemoteMirrorSnapshot, namespace: PersistenceNamespace) async throws {
        let context = try effectiveCandidate(candidate, snapshot: snapshot)
        let references = try decodedReferences(for: context.records)
        let state = try postBatchState(context.records, references: references, snapshot: snapshot, activeTransferIDs: context.activeTransferIDs)
        try validateReferences(context.records, references: references, state: state)
        try validateDeletions(state, snapshot: snapshot)
        try validateSupplementalRelationships(
            context.records.map(\.envelope), snapshot: snapshot, activeTransferIDs: context.activeTransferIDs, namespace: namespace)
    }

    private func effectiveCandidate(_ candidate: [VerifiedCloudRecord], snapshot: CloudRemoteMirrorSnapshot) throws -> CandidateValidationContext {
        let snapshotActiveTransferIDs = try eligibleActiveTransferIDs(in: snapshot.recordEnvelopesByResourceKey)
        var combined = snapshot.recordEnvelopesByResourceKey
        for verified in candidate { combined[verified.envelope.resourceKey] = verified.envelope }
        let activeTransferIDs = try eligibleActiveTransferIDs(in: combined)
        let activatingTransferIDs = activeTransferIDs.subtracting(snapshotActiveTransferIDs)
        let candidateKeys = Set(candidate.map(\.envelope.resourceKey))
        let activated = snapshot.recordEnvelopesByResourceKey.values.filter { envelope in
            guard case let .staged(transferID) = envelope.visibility else { return false }
            return activatingTransferIDs.contains(transferID) && !candidateKeys.contains(envelope.resourceKey)
        }.map { VerifiedCloudRecord(envelope: $0) }
        let visible = candidate.filter { verified in
            guard case let .staged(transferID) = verified.envelope.visibility else { return true }
            return activeTransferIDs.contains(transferID)
        }
        return CandidateValidationContext(records: visible + activated, activeTransferIDs: activeTransferIDs)
    }

    private func decodedReferences(for records: [VerifiedCloudRecord]) throws -> [ResourceKey: RecordReferences] {
        var references = [ResourceKey: RecordReferences]()
        var invalid = Set<ResourceKey>()
        for verified in records {
            let envelope = verified.envelope
            guard references[envelope.resourceKey] == nil else {
                invalid.insert(envelope.resourceKey)
                continue
            }
            do { references[envelope.resourceKey] = try self.references(for: envelope) } catch { invalid.insert(envelope.resourceKey) }
        }
        guard invalid.isEmpty else {
            throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: invalid, reason: "candidate reference payload could not be decoded")
        }
        return references
    }

    private func postBatchState(
        _ records: [VerifiedCloudRecord], references: [ResourceKey: RecordReferences], snapshot: CloudRemoteMirrorSnapshot, activeTransferIDs: Set<ObjectID>
    ) throws -> CandidatePostState {
        let hidden = Set(
            snapshot.recordEnvelopesByResourceKey.compactMap { key, envelope -> ResourceKey? in
                guard case let .staged(transferID) = envelope.visibility, !activeTransferIDs.contains(transferID) else { return nil }
                return key
            })
        var state = CandidatePostState(
            live: snapshot.existingResourceKeys.subtracting(snapshot.tombstonedResourceKeys).subtracting(hidden), tombstoned: snapshot.tombstonedResourceKeys)
        for verified in records { try apply(verified.envelope, references: references, snapshot: snapshot, to: &state) }
        state.live.subtract(state.deleted)
        state.tombstoned.formUnion(state.deleted)
        return state
    }

    private func apply(
        _ envelope: CloudRecordEnvelope, references: [ResourceKey: RecordReferences], snapshot: CloudRemoteMirrorSnapshot, to state: inout CandidatePostState
    ) throws {
        guard let extracted = references[envelope.resourceKey] else {
            throw CloudRemoteReferenceValidationError.invalidRecords(
                resourceKeys: [envelope.resourceKey], reason: "candidate reference payload could not be decoded")
        }
        if !envelope.isDeleted, extracted.deletedResourceKeys.isEmpty, snapshot.tombstonedResourceKeys.contains(envelope.resourceKey) {
            state.invalid.insert(envelope.resourceKey)
        }
        if envelope.isDeleted || !extracted.deletedResourceKeys.isEmpty {
            state.deletionSources.insert(envelope.resourceKey)
            state.deleted.formUnion(extracted.deletedResourceKeys.isEmpty ? [envelope.resourceKey] : extracted.deletedResourceKeys)
        } else {
            state.live.insert(envelope.resourceKey)
        }
    }

    private func validateReferences(_ records: [VerifiedCloudRecord], references: [ResourceKey: RecordReferences], state: CandidatePostState) throws {
        var invalid = state.invalid
        for verified in records {
            guard let extracted = references[verified.envelope.resourceKey] else {
                invalid.insert(verified.envelope.resourceKey)
                continue
            }
            validate(verified.envelope, references: extracted, state: state, invalid: &invalid)
        }
        guard invalid.isEmpty else {
            throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: invalid, reason: "candidate state contains missing or deleted references")
        }
    }

    private func validate(_ envelope: CloudRecordEnvelope, references: RecordReferences, state: CandidatePostState, invalid: inout Set<ResourceKey>) {
        guard !envelope.isDeleted, !references.deletedResourceKeys.contains(envelope.resourceKey) else { return }
        let missingHistorical = references.historicalReferences.contains { !state.live.contains($0) && !state.tombstoned.contains($0) }
        let missingLive = references.requiredLiveReferences.contains { !state.live.contains($0) || state.tombstoned.contains($0) }
        if missingHistorical || missingLive { invalid.insert(envelope.resourceKey) }
    }

    private func validateDeletions(_ state: CandidatePostState, snapshot: CloudRemoteMirrorSnapshot) throws {
        guard !state.deleted.isEmpty else { return }
        guard snapshot.hasCompleteReferenceIndex else {
            throw CloudRemoteReferenceValidationError.invalidRecords(
                resourceKeys: state.deletionSources, reason: "candidate deletion requires a complete persisted reference index")
        }
        let invalid = Set(
            snapshot.referencesByResourceKey.compactMap { source, references in
                state.live.contains(source) && !references.isDisjoint(with: state.deleted) ? source : nil
            })
        guard invalid.isEmpty else {
            throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: invalid, reason: "candidate state contains missing or deleted references")
        }
    }

    private func validateSupplementalRelationships(
        _ candidate: [CloudRecordEnvelope], snapshot: CloudRemoteMirrorSnapshot, activeTransferIDs: Set<ObjectID>, namespace: PersistenceNamespace
    ) throws {
        try validateAttachmentEvidenceRelationships(candidate: candidate, snapshot: snapshot, activeTransferIDs: activeTransferIDs)
        try validateFloorPlanAssetRelationships(candidate: candidate, snapshot: snapshot, activeTransferIDs: activeTransferIDs)
        try validateImportedHistoricalReferenceRelationships(
            candidate: candidate, snapshot: snapshot, activeTransferIDs: activeTransferIDs, namespace: namespace)
    }

    struct CandidateValidationContext {
        let records: [VerifiedCloudRecord]
        let activeTransferIDs: Set<ObjectID>
    }

    struct CandidatePostState {
        var live: Set<ResourceKey>
        var tombstoned: Set<ResourceKey>
        var deleted = Set<ResourceKey>()
        var deletionSources = Set<ResourceKey>()
        var invalid = Set<ResourceKey>()
    }
}
