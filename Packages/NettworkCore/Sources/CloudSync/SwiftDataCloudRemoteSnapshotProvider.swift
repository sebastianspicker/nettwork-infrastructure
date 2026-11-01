import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

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
        let preverified = try await preverifiedActiveTransferIDs(candidate, stored: records, namespace: namespace)
        let verifying = activationTransferIDs(candidate, stored: records).subtracting(preverified)
        try await appendTransferMembers(verifying, to: &records, namespace: namespace)
        return try mirrorSnapshot(records, namespace: namespace, preverified: preverified)
    }

    /// Staged members stay hidden until activation, so a staging batch fetches
    /// only the sessions of the transfers its closure reached, never all members.
    private func closureKeys(_ candidate: [VerifiedCloudRecord], namespace: PersistenceNamespace, transferIDs: inout Set<ObjectID>) async throws -> Set<
        ResourceKey
    > {
        var keys = try await boundedRelationClosure(candidate: candidate, namespace: namespace, transferIDs: &transferIDs)
        keys.insert(AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID))
        keys.formUnion(transferIDs.map(Self.sessionKey))
        guard keys.count <= Self.maximumRelationClosureKeys else {
            throw CloudRemoteReferenceValidationError.invalidRecords(
                resourceKeys: Set(candidate.map(\.envelope.resourceKey)), reason: "candidate relation closure exceeds key limit")
        }
        return keys
    }

    private static func sessionKey(_ transferID: ObjectID) -> ResourceKey { .string("workspace-transfer-session:\(transferID.description)") }

    /// The stored active transfer whose digest mirror apply already verified
    /// (persisted `.active` for the stored sentinel's commit), unless this
    /// candidate rewrites the workspace record away from that commit.
    private func preverifiedActiveTransferIDs(
        _ candidate: [VerifiedCloudRecord], stored: [LocalMirrorRecord], namespace: PersistenceNamespace
    ) async throws -> Set<ObjectID> {
        let key = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        guard let sentinel = stored.first(where: { $0.resourceKey == key }), !sentinel.isTombstone, let commit = sentinel.payload.flatMap(activeCommit),
            try await persistence.persistedWorkspaceVisibilityState(in: namespace)?.lifecycle == .active(commit: commit)
        else { return [] }
        let storedEnvelopes = Dictionary(stored.map { ($0.resourceKey, mirroredEnvelope($0, namespace: namespace)) }, uniquingKeysWith: { first, _ in first })
        let changed = CompositeCloudRemoteReferenceValidator.candidate(candidate.map(\.envelope), changesActivation: commit, stored: storedEnvelopes)
        return changed ? [] : [commit.transferID]
    }

    /// Every transfer an `.active` workspace record names, before or after the
    /// candidate: in practice the stored and the incoming activation.
    private func activationTransferIDs(_ candidate: [VerifiedCloudRecord], stored: [LocalMirrorRecord]) -> Set<ObjectID> {
        let incoming = candidate.map(\.envelope).filter { !$0.isDeleted && $0.recordType == CloudRecordNaming.workspaceRecordType }.map(\.payload)
        let persisted = stored.filter { !$0.isTombstone && $0.recordType == CloudRecordNaming.workspaceRecordType }.compactMap(\.payload)
        return Set((incoming + persisted).compactMap(activeCommit).map(\.transferID))
    }

    /// Activation needs the exact member set. Each transfer is bounded by
    /// `LocalMirrorMaintenanceLimits.maximumTransferMembersTotal`
    /// (`mirrorTransferMembers` throws above it), not by the closure budget.
    private func appendTransferMembers(_ transferIDs: Set<ObjectID>, to records: inout [LocalMirrorRecord], namespace: PersistenceNamespace) async throws {
        var keys = Set<ResourceKey>()
        for transferID in transferIDs {
            keys.insert(Self.sessionKey(transferID))
            keys.formUnion(try await persistence.mirrorTransferMembers(transferID: transferID, in: namespace).map(\.resourceKey))
        }
        keys.subtract(records.map(\.resourceKey))
        records.append(contentsOf: try await persistence.storedLocalMirrors(for: keys, in: namespace))
    }

    private func activeCommit(_ payload: Data) -> WorkspaceActivationCommit? {
        guard let workspace = try? CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: payload), case let .active(commit) = workspace.lifecycle
        else { return nil }
        return commit
    }

    private func mirrorSnapshot(_ records: [LocalMirrorRecord], namespace: PersistenceNamespace, preverified: Set<ObjectID>) throws
        -> CloudRemoteMirrorSnapshot
    {
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
            hasCompleteReferenceIndex: true, preverifiedActiveTransferIDs: preverified)
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
        let hidden = try await hiddenStagedKeys(candidate, namespace: namespace)
        try await checkHiddenStaged(hidden, candidateEnvelopes: candidateEnvelopes, namespace: namespace, transferIDs: &transferIDs)
        let roots = Set(candidateEnvelopes.keys).subtracting(hidden)
        if roots.isEmpty { return hidden }
        var closure = roots.union(hidden)
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

    /// Topology, hierarchy, IPAM and template records take part only in reference
    /// existence and deletion checks; the attachment, floor-plan and historical
    /// validators never trigger on them (floors bound by a floor-plan binding are
    /// the one structural case they need, see `reverseAnchors`).
    private static let structuralRecordTypes: Set<String> = [
        WorkspaceRecordType.location, WorkspaceRecordType.rack, WorkspaceRecordType.device, WorkspaceRecordType.deviceType,
        WorkspaceRecordType.module, WorkspaceRecordType.moduleTemplate, WorkspaceRecordType.port, WorkspaceRecordType.portTemplate,
        WorkspaceRecordType.cable, WorkspaceRecordType.internalLink, WorkspaceRecordType.topologyTombstone, WorkspaceRecordType.hierarchyTombstone,
        WorkspaceRecordType.workspaceHierarchy, WorkspaceRecordType.templatePlacementState, WorkspaceRecordType.rackPlacement,
        WorkspaceRecordType.floorPlanAnchor, WorkspaceRecordType.physicalTopology, WorkspaceRecordType.inventoryPortStateFact,
        WorkspaceRecordType.vrf, WorkspaceRecordType.prefix, WorkspaceRecordType.ipAddressRecord, WorkspaceRecordType.vlanGroup,
        WorkspaceRecordType.vlan, WorkspaceRecordType.interface, WorkspaceRecordType.ipAddressAssignment, WorkspaceRecordType.interfaceVLANMembership,
    ]

    /// Validation ignores candidates staged under a transfer that is neither
    /// active nor activated by this batch (`effectiveCandidate` filters them out).
    private func hiddenStagedKeys(_ candidate: [VerifiedCloudRecord], namespace: PersistenceNamespace) async throws -> Set<ResourceKey> {
        let sentinelKey = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: namespace.workspaceID)
        var active = Set(
            candidate.map(\.envelope).filter { !$0.isDeleted && $0.recordType == CloudRecordNaming.workspaceRecordType }
                .compactMap { activeCommit($0.payload)?.transferID })
        if let sentinel = try await persistence.storedLocalMirrors(for: [sentinelKey], in: namespace).first, !sentinel.isTombstone,
            let commit = sentinel.payload.flatMap(activeCommit)
        {
            active.insert(commit.transferID)
        }
        let persisted = try await persistence.persistedWorkspaceVisibilityState(in: namespace)
        if case let .active(commit)? = persisted?.lifecycle { active.insert(commit.transferID) }
        return Set(
            candidate.compactMap { verified in
                guard case let .staged(transferID) = verified.envelope.visibility, !active.contains(transferID) else { return nil }
                return verified.envelope.resourceKey
            })
    }

    /// Hidden candidates are fetched, not expanded: they keep the immutable-evidence
    /// check and contribute their transfer session.
    private func checkHiddenStaged(
        _ hidden: Set<ResourceKey>, candidateEnvelopes: [ResourceKey: CloudRecordEnvelope], namespace: PersistenceNamespace,
        transferIDs: inout Set<ObjectID>
    ) async throws {
        guard !hidden.isEmpty else { return }
        let stored = try await persistence.storedLocalMirrors(for: hidden, in: namespace)
        let storedEnvelopes = Dictionary(uniqueKeysWithValues: stored.map { ($0.resourceKey, mirroredEnvelope($0, namespace: namespace)) })
        let merged = try mergedEnvelopes(storedEnvelopes, candidate: candidateEnvelopes, frontier: hidden)
        for key in hidden { if let envelope = merged[key] { collectTransferID(from: envelope, into: &transferIDs) } }
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
        let reverseTargets = reverseExpansionTargets(frontier: frontier, merged: envelopes).union(relations.logicalDeletionTargets)
            .union(relations.reverseAnchors)
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

    /// Reverse edges are followed from every frontier record except a structural
    /// one that stays live: who references a site, rack or device type matters
    /// to no validator unless that record is deleted (deletions), and following
    /// them would pull in every sibling under a shared parent. Floors referenced
    /// by a floor-plan binding arrive as `reverseAnchors` (one binding per floor).
    private func reverseExpansionTargets(frontier: Set<ResourceKey>, merged: [ResourceKey: CloudRecordEnvelope]) -> Set<ResourceKey> {
        frontier.filter { key in
            guard let envelope = merged[key] else { return true }
            return envelope.isDeleted || !Self.structuralRecordTypes.contains(envelope.recordType)
        }
    }

    private func relationEdges(
        frontier: Set<ResourceKey>, stored: [ResourceKey: CloudRecordEnvelope], merged: [ResourceKey: CloudRecordEnvelope], transferIDs: inout Set<ObjectID>
    ) throws -> RelationEdges {
        var forward = Set<ResourceKey>()
        var logicalDeletionTargets = Set<ResourceKey>()
        var reverseAnchors = Set<ResourceKey>()
        for key in frontier {
            let versions = [stored[key], merged[key]].compactMap { $0 }
            for envelope in versions {
                let targets = try extractor.referencedResourceKeys(in: envelope)
                forward.formUnion(targets)
                if envelope.recordType == CloudRecordNaming.floorPlanAssetBindingRecordType { reverseAnchors.formUnion(targets) }
                logicalDeletionTargets.formUnion(try extractor.deletedResourceKeys(in: envelope))
                collectTransferID(from: envelope, into: &transferIDs)
            }
        }
        return RelationEdges(forward: forward, logicalDeletionTargets: logicalDeletionTargets, reverseAnchors: reverseAnchors)
    }

    private func collectTransferID(from envelope: CloudRecordEnvelope, into transferIDs: inout Set<ObjectID>) {
        if case let .staged(transferID) = envelope.visibility { transferIDs.insert(transferID) }
        guard envelope.recordType == CloudRecordNaming.workspaceRecordType, let commit = activeCommit(envelope.payload) else { return }
        transferIDs.insert(commit.transferID)
    }

    private struct RelationEdges {
        let forward: Set<ResourceKey>
        let logicalDeletionTargets: Set<ResourceKey>
        let reverseAnchors: Set<ResourceKey>
    }
    private struct RelationExpansion {
        let edges: Set<ResourceKey>
        let edgeVisits: Int
    }

    private func cloudRecordType(for persistedType: String) -> String {
        switch persistedType {
        case LocalRecordKind.physicalTopology: WorkspaceRecordType.physicalTopology
        case LocalRecordKind.workOrder: CloudRecordNaming.workOrderRecordType
        case LocalRecordKind.auditEvent: CloudRecordNaming.auditRecordType
        case LocalRecordKind.prefix: WorkspaceRecordType.prefix
        default: persistedType
        }
    }
}
