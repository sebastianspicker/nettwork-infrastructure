import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    func maintainMirrorIndexes(
        _ records: [LocalMirrorRecord], previous: [ResourceKey: LocalMirrorRecord?],
        maintenance: LocalMirrorMaintenanceBatch?, in namespace: PersistenceNamespace
    ) throws {
        guard let maintenance else {
            try markMirrorMaintenanceIncomplete(in: namespace)
            return
        }
        let state = try validatedMirrorMaintenanceState(maintenance, records: records, namespace: namespace)
        let facts = Dictionary(uniqueKeysWithValues: maintenance.records.map { ($0.resourceKey, $0) })
        var delta = MirrorIndexMaintenanceDelta()
        for record in records {
            guard let fact = facts[record.resourceKey] else {
                throw PersistenceStoreError.mirrorMaintenanceIncomplete
            }
            try maintainMirrorRecord(
                record, previous: previous[record.resourceKey] ?? nil, fact: fact, namespace: namespace, delta: &delta)
        }
        try applyMirrorAssetUsage(delta, namespace: namespace)
        try updateMirrorTransferUsage(delta.affectedTransfers, namespace: namespace)
        try applyMirrorMaintenanceState(delta, to: state)
    }

    func stagedTransferID(_ visibility: WorkspaceRecordVisibility) -> ObjectID? {
        guard case let .staged(transferID) = visibility else { return nil }
        return transferID
    }

    func isVisibleToFeatureProjection(
        _ record: LocalMirrorRecord, in namespace: PersistenceNamespace
    ) throws -> Bool {
        guard !isInfrastructureRecordType(record.recordType) else { return false }
        switch record.visibility {
        case .live:
            guard case .active = try workspaceVisibilityState(in: namespace).lifecycle else {
                return false
            }
            return true
        case let .staged(transferID):
            guard case let .active(commit) = try workspaceVisibilityState(in: namespace).lifecycle else {
                return false
            }
            return commit.transferID == transferID
        }
    }

    func rebuildInventorySearchIndexLocked(in namespace: PersistenceNamespace) throws {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let mirrors = try visibleInventoryMirrorRecords(in: namespace)
        let materialization = try InventorySearchIndexBuilder.materialize(records: mirrors, namespace: namespace)
        let state = try inventoryProjectionStateModel(matching: namespaceKey)
        if let state {
            state.isComplete = false
            state.schemaVersion = LocalInventoryProjectionStateModel.currentSchemaVersion
            state.updatedAt = .now
        } else {
            modelContext.insert(LocalInventoryProjectionStateModel(namespace: namespace, isComplete: false))
        }
        try inventorySearchIndexModels(namespaceKey: namespaceKey).forEach(modelContext.delete)
        try inventoryProjectionNodeModels(namespaceKey: namespaceKey).forEach(modelContext.delete)
        try inventoryProjectionEdgeModels(namespaceKey: namespaceKey).forEach(modelContext.delete)
        for node in materialization.nodes { modelContext.insert(try LocalInventoryProjectionNodeModel(record: node)) }
        for edge in materialization.edges {
            modelContext.insert(
                LocalInventoryProjectionEdgeModel(
                    namespace: namespace,
                    sourceKey: edge.source.description, targetKey: edge.target.description, kind: edge.kind))
        }
        for record in materialization.entries { modelContext.insert(try LocalInventorySearchIndexModel(record: record)) }
        let completeState = try inventoryProjectionStateModel(matching: namespaceKey)
        guard let completeState else { throw PersistenceStoreError.inventoryProjectionIncomplete }
        completeState.isComplete = true
        completeState.nodeCount = materialization.nodes.count
        completeState.edgeCount = materialization.edges.count
        completeState.entryCount = materialization.entries.count
        completeState.updatedAt = .now
    }

    struct InventoryProjectionSnapshot {
        let oldClosure: Set<String>
    }

    /// Captures only the old reverse closure before a verified write changes
    /// its dependency edges. This deliberately does not enumerate the mirror
    /// or compare complete before/after index projections.
    func inventoryProjectionSnapshot(
        for records: [LocalMirrorRecord], in namespace: PersistenceNamespace
    ) throws -> InventoryProjectionSnapshot? {
        guard try inventoryProjectionIsComplete(in: namespace) else { return nil }
        let seeds = Set(records.map { $0.resourceKey.description })
        return InventoryProjectionSnapshot(oldClosure: try inventoryProjectionClosure(from: seeds, in: namespace))
    }

    /// Re-normalizes only the dependency component touched by the batch. Old
    /// and new closures are unioned so tombstones remove their old incidence,
    /// while placements, cable endpoints, and pending work-order targets seed
    /// every new dependent before row replacement. Any incomplete component or
    /// bound hit fails closed into the transactional full materialization.
    func applyIncrementalInventoryProjection(
        _ changedRecords: [LocalMirrorRecord],
        snapshot: InventoryProjectionSnapshot, in namespace: PersistenceNamespace
    ) throws {
        let visibleChangedRecords = try changedRecords.filter {
            if $0.isTombstone { return false }
            return try isVisibleToFeatureProjection($0, in: namespace)
        }
        var dirtyKeys = snapshot.oldClosure
        let seeds = try InventorySearchIndexBuilder.directDependencySeeds(changedRecords)
        dirtyKeys.formUnion(changedRecords.map { $0.resourceKey.description })
        dirtyKeys.formUnion(seeds.dirty.map(\.description))
        dirtyKeys.formUnion(try inventoryProjectionClosure(from: dirtyKeys, in: namespace))
        guard dirtyKeys.count <= InventorySearchIndexBuilder.maximumIncrementalMutations else {
            try rebuildInventorySearchIndexLocked(in: namespace)
            return
        }
        var renderKeys = try inventoryProjectionContext(
            from: dirtyKeys.union(seeds.context.map(\.description)), in: namespace)
        var records = try inventoryProjectionRecords(keys: renderKeys, namespace: namespace)
        records.removeAll { record in changedRecords.contains { $0.resourceKey == record.resourceKey } }
        records.append(contentsOf: visibleChangedRecords)
        let preliminary = try InventorySearchIndexBuilder.materialize(records: records, namespace: namespace)
        let newDirtySeeds = Set(changedRecords.map { $0.resourceKey.description })
            .union(seeds.dirty.map(\.description))
        dirtyKeys.formUnion(
            try InventorySearchIndexBuilder.dirtyClosure(
                from: newDirtySeeds,
                edges: preliminary.edges))
        guard dirtyKeys.count <= InventorySearchIndexBuilder.maximumIncrementalMutations else {
            try rebuildInventorySearchIndexLocked(in: namespace)
            return
        }
        renderKeys = try inventoryProjectionContext(
            from: dirtyKeys.union(seeds.context.map(\.description)),
            in: namespace)
        records = try inventoryProjectionRecords(keys: renderKeys, namespace: namespace)
        records.removeAll { record in changedRecords.contains { $0.resourceKey == record.resourceKey } }
        records.append(contentsOf: visibleChangedRecords)
        let materialization = try InventorySearchIndexBuilder.materialize(records: records, namespace: namespace)
        guard materialization.entries.count <= InventorySearchIndexBuilder.maximumIncrementalMutations else {
            try rebuildInventorySearchIndexLocked(in: namespace)
            return
        }
        try replaceInventoryProjectionComponent(
            dirtyKeys: dirtyKeys, changedRecords: changedRecords,
            materialization: materialization, in: namespace)
    }

    func inventoryProjectionIsComplete(in namespace: PersistenceNamespace) throws -> Bool {
        let key = PersistenceNamespaceKey.value(for: namespace)
        guard let state = try inventoryProjectionStateModel(matching: key),
            state.schemaVersion == LocalInventoryProjectionStateModel.currentSchemaVersion,
            state.isComplete
        else {
            return false
        }
        return true
    }

    /// Open-time only reconciliation for stores migrated or interrupted while
    /// V8 was being introduced. Ordinary verified batches trust the atomic
    /// delta marker and never perform these namespace-wide count scans.
    func inventoryProjectionNeedsRepair(in namespace: PersistenceNamespace) throws -> Bool {
        let key = PersistenceNamespaceKey.value(for: namespace)
        guard let state = try inventoryProjectionStateModel(matching: key),
            state.schemaVersion == LocalInventoryProjectionStateModel.currentSchemaVersion,
            state.isComplete, state.nodeCount >= 0, state.edgeCount >= 0, state.entryCount >= 0,
            state.nodeCount <= InventorySearchIndexBuilder.maximumDerivedNodes,
            state.edgeCount <= InventorySearchIndexBuilder.maximumDerivedEdges,
            state.entryCount <= InventorySearchIndexBuilder.maximumEntries
        else {
            return true
        }
        // Read the model's counts before the short-circuiting `||` chain so its
        // autoclosures do not capture the non-Sendable SwiftData model.
        let nodeCount = state.nodeCount
        let edgeCount = state.edgeCount
        let entryCount = state.entryCount
        return try
            (nodeCount != inventoryProjectionNodeCount(in: namespace) || edgeCount != inventoryProjectionEdgeCount(in: namespace)
            || entryCount != inventorySearchIndexCount(in: namespace))
    }

    func inventoryProjectionClosure(from seeds: Set<String>, in namespace: PersistenceNamespace) throws -> Set<String> {
        try inventoryProjectionReachable(
            from: seeds, edgePrefix: "dirty.",
            maximumVisited: InventorySearchIndexBuilder.maximumIncrementalMutations, in: namespace)
    }

    /// Context edges are intentionally never re-fed into dirty propagation.
    /// They supply ancestors, types, port facts, and peer cable endpoints for
    /// exact component rendering while a leaf mutation remains local.
    func inventoryProjectionContext(from seeds: Set<String>, in namespace: PersistenceNamespace) throws -> Set<String> {
        try inventoryProjectionReachable(
            from: seeds, edgePrefix: "context.",
            maximumVisited: InventorySearchIndexBuilder.maximumDependencyVisits, in: namespace)
    }

    func inventoryProjectionReachable(
        from seeds: Set<String>, edgePrefix: String, maximumVisited: Int,
        in namespace: PersistenceNamespace,
        observer: SwiftDataPredicateFetchObserver? = nil
    ) throws -> Set<String> {
        var visited = seeds
        var frontier = seeds
        var visits = 0
        while !frontier.isEmpty {
            let edges = try inventoryProjectionEdges(sourceKeys: frontier, in: namespace, observer: observer)
            frontier.removeAll(keepingCapacity: true)
            visits += edges.count
            guard visits <= InventorySearchIndexBuilder.maximumDependencyVisits else {
                throw PersistenceStoreError.inventoryProjectionTraversalExceeded(visits)
            }
            for edge in edges where edge.kind.hasPrefix(edgePrefix) {
                guard visited.insert(edge.targetKey).inserted else { continue }
                guard visited.count <= maximumVisited else {
                    throw PersistenceStoreError.inventoryProjectionTraversalExceeded(visited.count)
                }
                frontier.insert(edge.targetKey)
            }
        }
        return visited
    }

    func inventoryProjectionRecords(keys: Set<String>, namespace: PersistenceNamespace) throws -> [LocalMirrorRecord] {
        guard keys.count <= InventorySearchIndexBuilder.maximumDependencyVisits else {
            throw PersistenceStoreError.inventoryProjectionTraversalExceeded(keys.count)
        }
        let storageKeys = keys.map {
            PersistenceNamespaceKey.storageKey(
                namespace: namespace,
                identity: "inventory-projection-node:\($0)")
        }
        var records: [LocalMirrorRecord] = []
        records.reserveCapacity(keys.count)
        for model in try inventoryProjectionNodeModels(storageKeys: storageKeys, namespace: namespace) {
            let resourceKey = try PersistenceCoding.decode(ResourceKey.self, from: model.resourceKeyData)
            records.append(
                LocalMirrorRecord(
                    namespace: namespace, resourceKey: resourceKey,
                    recordType: model.recordType, schemaVersion: 1, payload: model.payload, systemFields: nil,
                    changeTag: nil, isTombstone: model.isTombstone, serverModifiedAt: .distantPast,
                    verifiedAt: .distantPast))
        }
        return records.sorted { $0.resourceKey < $1.resourceKey }
    }
}
