import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

public enum CloudStagedAssetQuotaError: Error, Hashable, Sendable {
    case invalidPolicy
    case missingTransferSession(ObjectID)
    case abandonedTransfer(ObjectID)
    case duplicateAsset(ObjectID)
    case transferQuotaExceeded(ObjectID)
    case namespaceQuotaExceeded
}

public struct CloudStagedAssetQuotaPolicy: Hashable, Sendable {
    public let maximumAssetsPerTransfer: Int
    public let maximumBytesPerTransfer: Int
    public let maximumBytesPerNamespace: Int

    public init(
        maximumAssetsPerTransfer: Int, maximumBytesPerTransfer: Int, maximumBytesPerNamespace: Int
    ) throws {
        guard maximumAssetsPerTransfer > 0, maximumBytesPerTransfer > 0,
            maximumBytesPerNamespace >= maximumBytesPerTransfer
        else {
            throw CloudStagedAssetQuotaError.invalidPolicy
        }
        self.maximumAssetsPerTransfer = maximumAssetsPerTransfer
        self.maximumBytesPerTransfer = maximumBytesPerTransfer
        self.maximumBytesPerNamespace = maximumBytesPerNamespace
    }
}

/// Derives the complete V9 maintenance facts for one verified Cloud batch.
/// This stays separate from the actor so its fact mapping can be exercised
/// without a persistence container or an open namespace lease.
enum CloudMirrorMaintenanceFactBuilder {
    static func build(for records: [VerifiedCloudRecord]) throws -> LocalMirrorMaintenanceBatch {
        guard Set(records.map(\.envelope.resourceKey)).count == records.count else {
            throw CloudMirrorAdapterError.malformedPayload(
                records.first?.envelope.resourceKey ?? .string("batch"), "duplicate mirror resource key")
        }
        let referenceExtractor = CompositeCloudRemoteReferenceValidator()
        let facts = try records.map { verified -> LocalMirrorMaintenanceRecord in
            let envelope = verified.envelope
            let targets =
                envelope.isDeleted
                ? Set<ResourceKey>()
                : try referenceExtractor.referencedResourceKeys(in: envelope)
            let edges = Set(
                targets.map {
                    LocalMirrorReferenceEdge(source: envelope.resourceKey, target: $0)
                })
            let member: LocalMirrorTransferMember?
            if case let .staged(transferID) = envelope.visibility {
                member = LocalMirrorTransferMember(
                    transferID: transferID, resourceKey: envelope.resourceKey,
                    digest: CloudStagedTransferCommitment.member(envelope))
            } else {
                member = nil
            }
            return LocalMirrorMaintenanceRecord(
                resourceKey: envelope.resourceKey, references: edges,
                transferMember: member)
        }
        return LocalMirrorMaintenanceBatch(records: facts)
    }
}
