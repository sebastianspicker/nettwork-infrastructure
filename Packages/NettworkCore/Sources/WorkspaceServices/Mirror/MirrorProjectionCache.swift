import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl

/// Everything a read projection is built from except the mirror rows, which
/// the persisted `LocalMirrorRevision` stands in for. Conflicts and sync
/// state are compared by value, so capture, resolution and sync-state writes
/// invalidate too. Read these before the rows: a write that lands in between
/// leaves an older key, which only causes one extra rebuild.
struct MirrorProjectionInputs: Equatable {
    let revision: LocalMirrorRevision
    let conflicts: [ReconciliationCase]
    let conflictResourceKeys: Set<ResourceKey>
    let conflictCount: Int
    let syncState: LocalSyncState?

    init(persistence: SwiftDataPersistenceStore, namespace: PersistenceNamespace) async throws {
        revision = try await persistence.mirrorRevision(in: namespace)
        conflicts = try await persistence.unresolvedCases(in: namespace, limit: 200)
        conflictResourceKeys = try await persistence.unresolvedConflictResourceKeys(in: namespace)
        conflictCount = try await persistence.unresolvedConflictCount(in: namespace)
        syncState = try await persistence.syncState(in: namespace)
    }
}

/// The last projection one adapter built, reusable while its inputs match.
struct CachedMirrorProjection {
    let inputs: MirrorProjectionInputs
    let projection: MirrorProjection
}

extension Optional where Wrapped == CachedMirrorProjection {
    func reusable(for inputs: MirrorProjectionInputs) -> MirrorProjection? {
        guard let self, self.inputs == inputs else { return nil }
        return self.projection
    }
}
