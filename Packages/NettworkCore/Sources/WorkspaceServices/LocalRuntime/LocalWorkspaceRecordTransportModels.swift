import CloudSync
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Typed, fail-closed failures of the local record transport. None of them is
/// ever answered with an empty result or a silent full refetch.
public enum LocalWorkspaceRecordTransportError: Error, Equatable, Sendable {
    /// The transport serves exactly one local owner-private namespace.
    case unsupportedNamespace
    /// A read or write named a workspace zone other than the served one.
    case zoneMismatch
    /// The persisted change token belongs to another store, workspace or a future revision.
    case foreignChangeToken
    case malformedChangeToken
    case unsupportedChangeTokenVersion(Int)
    /// A single store revision exceeds the per-batch record or byte limit.
    case changeBatchTooLarge
    /// The exact record is a tombstone; it has no live state to condition on.
    case tombstonedRecord(ResourceKey)
    case malformedStoredRecord(ResourceKey)
    case receiptPayloadMissing
    /// An assertion-preserving record differs from the stored record it asserts.
    case assertionMismatch(ResourceKey)
}

extension LocalWorkspaceRecordTransportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedNamespace: "The local record transport only serves a local owner-private workspace."
        case .zoneMismatch: "The request names a workspace zone this local transport does not serve."
        case .foreignChangeToken: "The persisted change token does not belong to this local workspace store."
        case .malformedChangeToken: "The persisted change token is malformed."
        case .unsupportedChangeTokenVersion(let version): "The persisted change token uses unsupported format version \(version)."
        case .changeBatchTooLarge: "A local workspace change exceeds the synchronization batch limits."
        case .tombstonedRecord(let key): "The record \(key) is deleted."
        case .malformedStoredRecord(let key): "The stored record \(key) is malformed."
        case .receiptPayloadMissing: "The mutation does not contain an operation receipt."
        case .assertionMismatch(let key): "The asserted record \(key) does not match the stored record."
        }
    }
}

/// Opaque `CloudChangeBatch.newState` of the local backend (`formatVersion` 1,
/// deterministic JSON). It binds the store incarnation and workspace, so a
/// token from a reset or different store is rejected instead of reinterpreted.
struct LocalWorkspaceChangeToken: Codable, Equatable, Sendable {
    static let currentFormatVersion = 1

    let formatVersion: Int
    let incarnation: UUID
    let workspaceID: ObjectID
    let revision: UInt64

    init(incarnation: UUID, workspaceID: ObjectID, revision: UInt64) {
        self.formatVersion = Self.currentFormatVersion
        self.incarnation = incarnation
        self.workspaceID = workspaceID
        self.revision = revision
    }

    func encoded() throws -> Data { try CloudDeterministicCoding.encode(self) }

    /// Decodes a persisted token; anything but a well-formed current-version token throws.
    static func decode(_ data: Data) throws -> LocalWorkspaceChangeToken {
        let token: LocalWorkspaceChangeToken
        do { token = try CloudDeterministicCoding.decode(LocalWorkspaceChangeToken.self, from: data) } catch {
            throw LocalWorkspaceRecordTransportError.malformedChangeToken
        }
        guard token.formatVersion == currentFormatVersion else {
            throw LocalWorkspaceRecordTransportError.unsupportedChangeTokenVersion(token.formatVersion)
        }
        return token
    }
}

/// Result of the shared all-or-nothing commit core.
enum LocalCommitOutcome: Sendable {
    case committed
    /// The first unmet precondition: the envelope it guards and the stored record, if any.
    case conflict(envelope: CloudRecordEnvelope, stored: LocalStoredRecord?)
}

/// Thrown by the test-only fault hook after a commit really persisted.
struct LocalSimulatedIndeterminateCommit: Error {}
