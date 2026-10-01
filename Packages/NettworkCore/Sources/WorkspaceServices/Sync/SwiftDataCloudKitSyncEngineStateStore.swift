import CloudSync
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

enum SwiftDataCloudKitSyncEngineStateStoreError: Error, Hashable, Sendable {
    case namespaceMismatch
    case unappliedState(PersistenceNamespace)
}

/// Bridges CKSyncEngine's opaque serialized cursor to the same transaction
/// that makes a verified mirror batch visible. `persistAppliedState` is an
/// acknowledgement check, not a second cursor write: the mirror store has
/// already committed the exact state beside the records it describes.
public actor SwiftDataCloudKitSyncEngineStateStore: CloudKitSyncEngineStateStore {
    private let persistence: SwiftDataPersistenceStore
    private let namespace: PersistenceNamespace

    public init(persistence: SwiftDataPersistenceStore, namespace: PersistenceNamespace) {
        self.persistence = persistence
        self.namespace = namespace
    }

    public func persistedState(in requestedNamespace: PersistenceNamespace) async throws -> Data? {
        try requireNamespace(requestedNamespace)
        return try await persistence.syncState(in: requestedNamespace)?.engineState
    }

    public func persistAppliedState(_ state: Data, in requestedNamespace: PersistenceNamespace) async throws {
        try requireNamespace(requestedNamespace)
        guard try await persistence.syncState(in: requestedNamespace)?.engineState == state else {
            throw SwiftDataCloudKitSyncEngineStateStoreError.unappliedState(requestedNamespace)
        }
    }

    private func requireNamespace(_ requestedNamespace: PersistenceNamespace) throws {
        guard requestedNamespace == namespace else {
            throw SwiftDataCloudKitSyncEngineStateStoreError.namespaceMismatch
        }
    }
}
