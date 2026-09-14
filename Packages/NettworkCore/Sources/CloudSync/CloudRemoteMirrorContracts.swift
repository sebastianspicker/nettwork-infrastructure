import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

public enum CloudMirrorAdapterError: Error, Hashable, Sendable {
    case namespaceNotOpen(PersistenceNamespace)
    case unsupportedSemanticRecord(String)
    case malformedPayload(ResourceKey, String)
}

/// The application supplies domain-specific cross-reference checks here. The
/// bridge will not turn an unvalidated remote record into a SwiftData mirror.
public protocol CloudRemoteSemanticValidator: Sendable {
    func validate(_ records: [VerifiedCloudRecord], namespace: PersistenceNamespace) async throws
}

/// A compact, already-scoped view of the persisted mirror used to validate a
/// proposed complete remote batch before it becomes visible.
public struct CloudRemoteMirrorSnapshot: Hashable, Sendable {
    public let existingResourceKeys: Set<ResourceKey>
    public let tombstonedResourceKeys: Set<ResourceKey>
    /// Reverse edges for already-applied records. A complete index is required
    /// before a candidate may delete a referenced record, because the compact
    /// key sets alone cannot prove that no durable dependent remains.
    public let referencesByResourceKey: [ResourceKey: Set<ResourceKey>]
    /// Raw persisted envelopes are retained only for staged-transfer admission.
    /// They let the validator defer cross-record checks while a transfer is
    /// incomplete, then validate the complete hidden graph when its workspace
    /// activation marker arrives.
    public let recordEnvelopesByResourceKey: [ResourceKey: CloudRecordEnvelope]
    public let hasCompleteReferenceIndex: Bool

    public init(
        existingResourceKeys: Set<ResourceKey>, tombstonedResourceKeys: Set<ResourceKey>,
        referencesByResourceKey: [ResourceKey: Set<ResourceKey>] = [:],
        recordEnvelopesByResourceKey: [ResourceKey: CloudRecordEnvelope] = [:],
        hasCompleteReferenceIndex: Bool = false
    ) {
        self.existingResourceKeys = existingResourceKeys
        self.tombstonedResourceKeys = tombstonedResourceKeys
        self.referencesByResourceKey = referencesByResourceKey
        self.recordEnvelopesByResourceKey = recordEnvelopesByResourceKey
        self.hasCompleteReferenceIndex = hasCompleteReferenceIndex
    }
}

public protocol CloudRemoteSnapshotProvider: Sendable {
    func snapshot(in namespace: PersistenceNamespace) async throws -> CloudRemoteMirrorSnapshot
}

public enum CloudRemoteReferenceValidationError: Error, Hashable, Sendable {
    case invalidRecords(resourceKeys: Set<ResourceKey>, reason: String)

    public var invalidResourceKeys: Set<ResourceKey> {
        switch self {
        case let .invalidRecords(resourceKeys, _): resourceKeys
        }
    }
}

/// Production composition owns reference extraction and candidate-state rules.
/// It receives the complete candidate batch plus durable live/tombstone state,
/// so it can reject resurrection and missing references without applying a
/// partial batch.
public protocol CloudRemoteReferenceValidator: Sendable {
    func validate(candidate: [VerifiedCloudRecord], against snapshot: CloudRemoteMirrorSnapshot, namespace: PersistenceNamespace) async throws
}

/// Baseline candidate check for every production composition. A caller may
/// compose richer topology/IPAM reference checks after this one, but a known
/// tombstone can never be silently resurrected by a remote batch.
public struct TombstoneAwareCloudRemoteReferenceValidator: CloudRemoteReferenceValidator {
    public init() {}

    public func validate(candidate: [VerifiedCloudRecord], against snapshot: CloudRemoteMirrorSnapshot, namespace: PersistenceNamespace) async throws {
        let resurrected = Set(
            candidate.compactMap { record -> ResourceKey? in
                let envelope = record.envelope
                return !envelope.isDeleted && snapshot.tombstonedResourceKeys.contains(envelope.resourceKey) ? envelope.resourceKey : nil
            })
        guard resurrected.isEmpty else {
            throw CloudRemoteReferenceValidationError.invalidRecords(resourceKeys: resurrected, reason: "candidate resurrects a durable tombstone")
        }
    }
}

/// Production validator for the complete registered domain schema. It derives
/// a post-batch candidate state before checking references, so creation order
/// within a batch cannot change validity and a deletion cannot leave either a
/// candidate or an indexed durable record pointing at a missing dependency.
///
/// `AuditEvent` references are historical evidence: they may resolve to a live
/// record or a retained tombstone. Operational references (topology, IPAM,
/// active work-order reservations, and operation receipts) require a live
/// candidate-state target.
public struct CompositeCloudRemoteReferenceValidator: CloudRemoteReferenceValidator {
    public init() {}

    /// Reference extraction used by the persisted snapshot builder. A complete
    /// index must be rebuilt from every live row before deletion is allowed.
    public func referencedResourceKeys(in envelope: CloudRecordEnvelope) throws -> Set<ResourceKey> {
        let extracted = try references(for: envelope)
        return extracted.requiredLiveReferences.union(extracted.historicalReferences)
    }

    /// Candidate snapshot construction also needs typed logical deletion
    /// targets (for example topology tombstones whose envelope key is not the
    /// deleted row). The reverse index closes those targets without scanning.
    public func deletedResourceKeys(in envelope: CloudRecordEnvelope) throws -> Set<ResourceKey> {
        try references(for: envelope).deletedResourceKeys
    }
}
