import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

public enum CloudRemoteReferenceValidators {
    /// Use this in production `SwiftDataCloudMirrorStore` composition.
    public static let production = CompositeCloudRemoteReferenceValidator()
}

/// Builds a candidate-scoped view from V9 indexes. A generic protocol caller
/// receives an intentionally incomplete empty snapshot; production calls the
/// overload below with the actual candidate and therefore never enumerates a
/// mirror namespace during ordinary validation.
public struct SwiftDataCloudRemoteSnapshotProvider: CloudRemoteSnapshotProvider {
    private static let maximumRelationClosureKeys = 4_096
    private static let maximumRelationClosureEdges = 8_192
    private let persistence: SwiftDataPersistenceStore
    private let extractor: CompositeCloudRemoteReferenceValidator

    public init(persistence: SwiftDataPersistenceStore, extractor: CompositeCloudRemoteReferenceValidator = .init()) {
        self.persistence = persistence
        self.extractor = extractor
    }

    public func snapshot(in namespace: PersistenceNamespace) async throws -> CloudRemoteMirrorSnapshot {
        _ = try await persistence.mirrorMaintenanceNeedsRepair(in: namespace)
        return CloudRemoteMirrorSnapshot(
            existingResourceKeys: [],
            tombstonedResourceKeys: [],
            hasCompleteReferenceIndex: false
        )
    }

    public func snapshot(
        candidate: [VerifiedCloudRecord], in namespace: PersistenceNamespace
    ) async throws -> CloudRemoteMirrorSnapshot {
        guard !(try await persistence.mirrorMaintenanceNeedsRepair(in: namespace)) else {
            return CloudRemoteMirrorSnapshot(
                existingResourceKeys: [],
                tombstonedResourceKeys: [],
                hasCompleteReferenceIndex: false
            )
        }
        var transferIDs = Set<ObjectID>()
        let required = try await closureKeys(candidate, namespace: namespace, transferIDs: &transferIDs)
        var records = try await persistence.storedLocalMirrors(for: required, in: namespace)
        try await appendActiveTransfer(to: &records, namespace: namespace, knownTransferIDs: transferIDs)
        return try mirrorSnapshot(records, namespace: namespace)
    }

    private func closureKeys(_ candidate: [VerifiedCloudRecord], namespace: PersistenceNamespace, transferIDs: inout Set<ObjectID>) async throws -> Set<
        ResourceKey
    > {
        var keys = try await boundedRelationClosure(candidate: candidate, namespace: namespace, transferIDs: &transferIDs)
        keys.insert(AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID))
        for id in transferIDs { try await appendTransferKeys(id, to: &keys, namespace: namespace) }
        guard keys.count <= Self.maximumRelationClosureKeys else {
            throw CloudRemoteReferenceValidationError.invalidRecords(
                resourceKeys: Set(candidate.map(\.envelope.resourceKey)), reason: "candidate relation closure exceeds key limit")
        }
        return keys
    }

    private func appendTransferKeys(_ transferID: ObjectID, to keys: inout Set<ResourceKey>, namespace: PersistenceNamespace) async throws {
        keys.insert(.string("workspace-transfer-session:\(transferID.description)"))
        keys.formUnion(try await persistence.mirrorTransferMembers(transferID: transferID, in: namespace).map(\.resourceKey))
    }

    private func appendActiveTransfer(to records: inout [LocalMirrorRecord], namespace: PersistenceNamespace, knownTransferIDs: Set<ObjectID>) async throws {
        let key = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        guard let record = records.first(where: { $0.resourceKey == key }), let payload = record.payload,
            let workspace = try? CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: payload),
            case let .active(commit) = workspace.lifecycle, !knownTransferIDs.contains(commit.transferID)
        else { return }
        var keys = Set<ResourceKey>()
        try await appendTransferKeys(commit.transferID, to: &keys, namespace: namespace)
        let extra = try await persistence.storedLocalMirrors(for: keys, in: namespace)
        records.append(contentsOf: extra.filter { item in !records.contains(where: { $0.resourceKey == item.resourceKey }) })
    }

    private func mirrorSnapshot(_ records: [LocalMirrorRecord], namespace: PersistenceNamespace) throws -> CloudRemoteMirrorSnapshot {
        var existing = Set<ResourceKey>()
        var tombstoned = Set<ResourceKey>()
        var references = [ResourceKey: Set<ResourceKey>]()
        var envelopes = [ResourceKey: CloudRecordEnvelope]()
        for record in records {
            existing.insert(record.resourceKey)
            let envelope = mirroredEnvelope(record, namespace: namespace)
            envelopes[record.resourceKey] = envelope
            if record.isTombstone {
                tombstoned.insert(record.resourceKey)
            } else {
                references[record.resourceKey] = try extractor.referencedResourceKeys(in: envelope)
            }
        }
        return CloudRemoteMirrorSnapshot(
            existingResourceKeys: existing, tombstonedResourceKeys: tombstoned, referencesByResourceKey: references, recordEnvelopesByResourceKey: envelopes,
            hasCompleteReferenceIndex: true)
    }

    private func mirroredEnvelope(_ record: LocalMirrorRecord, namespace: PersistenceNamespace) -> CloudRecordEnvelope {
        CloudRecordEnvelope(
            recordName: CloudRecordNaming.recordName(for: record.resourceKey, workspaceID: namespace.workspaceID), resourceKey: record.resourceKey,
            workspaceID: namespace.workspaceID,
            recordType: cloudRecordType(for: record.recordType), schemaVersion: record.schemaVersion, payload: record.payload ?? Data(),
            visibility: record.visibility, systemFields: record.systemFields ?? Data(),
            changeTag: record.changeTag ?? "", isDeleted: record.isTombstone)
    }

    /// Bounded bidirectional closure for relationship validators. Every
    /// expansion is either an exact stored-row fetch, a forward extractor
    /// edge, or a V9 reverse-edge query. If we cannot prove closure within the
    /// budget, the snapshot stays unavailable and validation fails closed.
    private func boundedRelationClosure(
        candidate: [VerifiedCloudRecord], namespace: PersistenceNamespace,
        transferIDs: inout Set<ObjectID>
    ) async throws -> Set<ResourceKey> {
        let candidateEnvelopes = Dictionary(uniqueKeysWithValues: candidate.map { ($0.envelope.resourceKey, $0.envelope) })
        let roots = Set(candidateEnvelopes.keys)
        var closure = roots
        var frontier = roots
        var edgeVisits = 0
        while !frontier.isEmpty {
            guard closure.count <= Self.maximumRelationClosureKeys else {
                throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: roots, reason: "candidate relation closure exceeds key limit")
            }
            let expansion = try await relationExpansion(
                frontier: frontier, candidateEnvelopes: candidateEnvelopes, namespace: namespace, edgeVisits: edgeVisits, roots: roots,
                transferIDs: &transferIDs)
            edgeVisits = expansion.edgeVisits
            let additions = expansion.edges.subtracting(closure)
            closure.formUnion(additions)
            frontier = additions
        }
        return closure
    }

    private func relationExpansion(
        frontier: Set<ResourceKey>, candidateEnvelopes: [ResourceKey: CloudRecordEnvelope], namespace: PersistenceNamespace, edgeVisits: Int,
        roots: Set<ResourceKey>,
        transferIDs: inout Set<ObjectID>
    ) async throws -> RelationExpansion {
        let stored = try await persistence.storedLocalMirrors(for: frontier, in: namespace)
        let storedEnvelopes = Dictionary(uniqueKeysWithValues: stored.map { ($0.resourceKey, mirroredEnvelope($0, namespace: namespace)) })
        let envelopes = try mergedEnvelopes(storedEnvelopes, candidate: candidateEnvelopes, frontier: frontier)
        let relations = try relationEdges(frontier: frontier, stored: storedEnvelopes, merged: envelopes, transferIDs: &transferIDs)
        let remainingEdgeBudget = Self.maximumRelationClosureEdges - edgeVisits - relations.forward.count
        guard remainingEdgeBudget > 0 else {
            throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: roots, reason: "candidate relation closure exceeds edge limit")
        }
        let reverseTargets = frontier.union(relations.logicalDeletionTargets)
        let reverse = try await persistence.mirrorReferenceSources(targeting: reverseTargets, remainingBudget: remainingEdgeBudget, in: namespace)
        let nextEdgeVisits = edgeVisits + relations.forward.count + reverse.count
        guard nextEdgeVisits <= Self.maximumRelationClosureEdges else {
            throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: roots, reason: "candidate relation closure exceeds edge limit")
        }
        return RelationExpansion(edges: relations.forward.union(reverse), edgeVisits: nextEdgeVisits)
    }

    private func mergedEnvelopes(_ stored: [ResourceKey: CloudRecordEnvelope], candidate: [ResourceKey: CloudRecordEnvelope], frontier: Set<ResourceKey>) throws
        -> [ResourceKey: CloudRecordEnvelope]
    {
        var merged = stored
        for (key, envelope) in candidate where frontier.contains(key) {
            if let old = stored[key] { try validateImmutableEvidence(old: old, replacement: envelope, key: key) }
            merged[key] = envelope
        }
        return merged
    }

    private func validateImmutableEvidence(old: CloudRecordEnvelope, replacement: CloudRecordEnvelope, key: ResourceKey) throws {
        let protectedTypes: Set<String> = [
            CloudRecordNaming.attachmentEvidenceBindingRecordType, CloudRecordNaming.attachmentEvidenceReservationReleaseRecordType,
        ]
        guard protectedTypes.contains(old.recordType) || protectedTypes.contains(replacement.recordType) else { return }
        let matches = [
            old.recordType == replacement.recordType, old.payload == replacement.payload, old.visibility == replacement.visibility,
            old.isDeleted == replacement.isDeleted,
        ]
        guard !matches.contains(false) else {
            throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: [key], reason: "immutable attachment evidence record changed")
        }
    }

    private func relationEdges(
        frontier: Set<ResourceKey>, stored: [ResourceKey: CloudRecordEnvelope], merged: [ResourceKey: CloudRecordEnvelope], transferIDs: inout Set<ObjectID>
    ) throws -> RelationEdges {
        var forward = Set<ResourceKey>()
        var logicalDeletionTargets = Set<ResourceKey>()
        for key in frontier {
            let versions = [stored[key], merged[key]].compactMap { $0 }
            for envelope in versions {
                forward.formUnion(try extractor.referencedResourceKeys(in: envelope))
                logicalDeletionTargets.formUnion(try extractor.deletedResourceKeys(in: envelope))
                collectTransferID(from: envelope, into: &transferIDs)
            }
        }
        return RelationEdges(forward: forward, logicalDeletionTargets: logicalDeletionTargets)
    }

    private func collectTransferID(from envelope: CloudRecordEnvelope, into transferIDs: inout Set<ObjectID>) {
        if case let .staged(transferID) = envelope.visibility { transferIDs.insert(transferID) }
        guard envelope.recordType == CloudRecordNaming.workspaceRecordType,
            let workspace = try? CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: envelope.payload),
            case let .active(commit) = workspace.lifecycle
        else { return }
        transferIDs.insert(commit.transferID)
    }

    private struct RelationEdges {
        let forward: Set<ResourceKey>
        let logicalDeletionTargets: Set<ResourceKey>
    }
    private struct RelationExpansion {
        let edges: Set<ResourceKey>
        let edgeVisits: Int
    }

    private func cloudRecordType(for persistedType: String) -> String {
        switch persistedType {
        case LocalRecordKind.physicalTopology: "NettworkPhysicalTopology"
        case LocalRecordKind.workOrder: CloudRecordNaming.workOrderRecordType
        case LocalRecordKind.auditEvent: CloudRecordNaming.auditRecordType
        case LocalRecordKind.prefix: "NettworkPrefix"
        default: persistedType
        }
    }
}
