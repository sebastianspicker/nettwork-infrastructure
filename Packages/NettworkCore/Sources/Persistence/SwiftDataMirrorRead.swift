import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    public func inventorySearchRecords(
        in namespace: PersistenceNamespace, kinds: Set<String>,
        siteID: ObjectID?, text: String, limit: Int
    ) throws -> [LocalInventorySearchRecord] {
        guard (1...50).contains(limit) else { throw PersistenceStoreError.invalidReadLimit }
        try validateActiveLease(for: namespace)
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard needle.lengthOfBytes(using: .utf8) <= 1_024 else { throw PersistenceStoreError.invalidReadLimit }
        let requestedKinds =
            kinds.isEmpty
            ? ["site", "room", "rack", "device", "port", "cable", "address", "interface"]
            : kinds.sorted()
        let siteToken = siteID.map(LocalInventorySearchIndexModel.siteMembershipToken(for:))
        let records = try fetchInventorySearchRecords(
            kinds: requestedKinds, siteToken: siteToken, needle: needle, limit: limit, namespaceKey: namespaceKey, namespace: namespace)
        return records.sorted(by: inventorySearchRecordOrder).prefix(limit).map { $0 }
    }

    func fetchInventorySearchRecords(
        kinds: [String], siteToken: String?, needle: String, limit: Int,
        namespaceKey: String, namespace: PersistenceNamespace
    ) throws -> [LocalInventorySearchRecord] {
        var records: [LocalInventorySearchRecord] = []
        records.reserveCapacity(kinds.count * limit)
        for kind in kinds {
            let descriptor = inventorySearchDescriptor(kind: kind, siteToken: siteToken, needle: needle, namespaceKey: namespaceKey)
            var bounded = descriptor
            bounded.fetchLimit = limit
            records.append(contentsOf: try modelContext.fetch(bounded).map { try decodeInventorySearchRecord($0, namespace: namespace) })
        }
        return records
    }

    func inventorySearchDescriptor(kind: String, siteToken: String?, needle: String, namespaceKey: String) -> FetchDescriptor<LocalInventorySearchIndexModel> {
        switch (siteToken, needle.isEmpty) {
        case let (.some(token), false): return inventorySearchDescriptor(kind: kind, token: token, needle: needle, namespaceKey: namespaceKey)
        case let (.some(token), true): return inventorySearchDescriptor(kind: kind, token: token, namespaceKey: namespaceKey)
        case (.none, false): return inventorySearchDescriptor(kind: kind, needle: needle, namespaceKey: namespaceKey)
        case (.none, true): return inventorySearchDescriptor(kind: kind, namespaceKey: namespaceKey)
        }
    }

    func inventorySearchDescriptor(kind: String, token: String, needle: String, namespaceKey: String) -> FetchDescriptor<LocalInventorySearchIndexModel> {
        FetchDescriptor(
            predicate: #Predicate {
                $0.namespaceKey == namespaceKey && $0.kind == kind && $0.siteMembershipTokens.contains(token) && $0.searchText.contains(needle)
            },
            sortBy: [
                SortDescriptor(\.title),
                SortDescriptor(\.objectIDValue),
            ])
    }

    func inventorySearchDescriptor(kind: String, token: String, namespaceKey: String) -> FetchDescriptor<LocalInventorySearchIndexModel> {
        FetchDescriptor(
            predicate: #Predicate { $0.namespaceKey == namespaceKey && $0.kind == kind && $0.siteMembershipTokens.contains(token) },
            sortBy: [SortDescriptor(\.title), SortDescriptor(\.objectIDValue)])
    }

    func inventorySearchDescriptor(kind: String, needle: String, namespaceKey: String) -> FetchDescriptor<LocalInventorySearchIndexModel> {
        FetchDescriptor(
            predicate: #Predicate { $0.namespaceKey == namespaceKey && $0.kind == kind && $0.searchText.contains(needle) },
            sortBy: [SortDescriptor(\.title), SortDescriptor(\.objectIDValue)])
    }

    func inventorySearchDescriptor(kind: String, namespaceKey: String) -> FetchDescriptor<LocalInventorySearchIndexModel> {
        FetchDescriptor(
            predicate: #Predicate { $0.namespaceKey == namespaceKey && $0.kind == kind }, sortBy: [SortDescriptor(\.title), SortDescriptor(\.objectIDValue)])
    }

    func inventorySearchRecordOrder(_ lhs: LocalInventorySearchRecord, _ rhs: LocalInventorySearchRecord) -> Bool {
        let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
        return titleOrder == .orderedSame ? lhs.objectID < rhs.objectID : titleOrder == .orderedAscending
    }

    /// Backfills a newly opened or migrated namespace from its already-
    /// verified mirror. The V8 node/edge/index/state replacement is one
    /// transaction, so no partial materialization is ever marked complete.
    public func materializeInventorySearchProjection(in namespace: PersistenceNamespace) throws {
        try transaction {
            try validateActiveLease(for: namespace)
            if try inventoryProjectionNeedsRepair(in: namespace) {
                try rebuildInventorySearchIndexLocked(in: namespace)
            }
        }
    }

    /// Compatibility spelling for callers that predate the V8 derived graph.
    public func rebuildInventorySearchIndex(in namespace: PersistenceNamespace) throws {
        try transaction {
            try validateActiveLease(for: namespace)
            try rebuildInventorySearchIndexLocked(in: namespace)
        }
    }

    public func workspaceVisibilityState(in namespace: PersistenceNamespace) throws -> LocalWorkspaceVisibilityState {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        guard let model = try workspaceVisibilityStateModel(matching: key) else {
            return LocalWorkspaceVisibilityState(namespace: namespace, lifecycle: .empty(epoch: 0))
        }
        let state = try PersistenceCoding.decode(LocalWorkspaceVisibilityState.self, from: model.stateData)
        guard state.namespace == namespace else { throw PersistenceStoreError.malformedStoredValue("workspace visibility namespace") }
        return state
    }

    public func syncState(in namespace: PersistenceNamespace) throws -> LocalSyncState? {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        guard let model = try syncStateModel(matching: key) else { return nil }
        let state = try PersistenceCoding.decode(LocalSyncState.self, from: model.stateData)
        guard state.namespace == namespace else { throw PersistenceStoreError.malformedStoredValue("sync state namespace") }
        return state
    }

    public func quarantine(_ record: LocalQuarantineRecord) throws {
        try transaction {
            try validateActiveLease(for: record.namespace)
            modelContext.insert(try LocalQuarantineModel(record: record))
        }
    }

    public func quarantinedRecords(in namespace: PersistenceNamespace) throws -> [LocalQuarantineRecord] {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        return try quarantineModels(namespaceKey: key)
            .map { try PersistenceCoding.decode(LocalQuarantineRecord.self, from: $0.recordData) }
            .filter { $0.namespace == namespace }.sorted { $0.capturedAt < $1.capturedAt }
    }

    public func quarantinedRecords(in namespace: PersistenceNamespace, limit: Int) throws -> [LocalQuarantineRecord] {
        guard (1...10_000).contains(limit) else { throw PersistenceStoreError.invalidReadLimit }
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        var descriptor = FetchDescriptor<LocalQuarantineModel>(predicate: #Predicate { $0.namespaceKey == key })
        descriptor.fetchLimit = limit
        return try modelContext.fetch(descriptor)
            .map { try PersistenceCoding.decode(LocalQuarantineRecord.self, from: $0.recordData) }
            .filter { $0.namespace == namespace }.sorted { $0.capturedAt < $1.capturedAt }
    }

    public func quarantineCount(in namespace: PersistenceNamespace) throws -> Int {
        try validateActiveLease(for: namespace)
        let key = PersistenceNamespaceKey.value(for: namespace)
        let descriptor = FetchDescriptor<LocalQuarantineModel>(predicate: #Predicate { $0.namespaceKey == key })
        return try modelContext.fetchCount(descriptor)
    }

    /// A rebuild clears only reconstructable mirror and sync cursor data.
    /// Pending intent, receipts, conflicts, attachments, quarantine data, and
    /// record-name identities remain durable evidence for replay or manual
    /// reconciliation. Identity evidence is retained so a later CloudKit
    /// deletion remains attributable after the mirror itself is rebuilt.
    public func rebuildMirror(in namespace: PersistenceNamespace) throws -> MirrorRebuildResult {
        try transaction {
            try validateActiveLease(for: namespace)
            let key = PersistenceNamespaceKey.value(for: namespace)
            let mirrors = try mirrorModels(namespaceKey: key)
            let inventoryIndex = try inventorySearchIndexModels(namespaceKey: key)
            let inventoryProjectionNodes = try inventoryProjectionNodeModels(namespaceKey: key)
            let inventoryProjectionEdges = try inventoryProjectionEdgeModels(namespaceKey: key)
            let inventoryProjectionState = try inventoryProjectionStateModel(matching: key)
            let operations = try decodedOperations(namespace: namespace)
            let receipts = try receiptModels(namespaceKey: key)
            let conflicts = try conflictModels(namespaceKey: key)
            let states = try syncStateModels(namespaceKey: key)
            let visibility = try workspaceVisibilityStateModel(matching: key)
            mirrors.forEach(modelContext.delete)
            inventoryIndex.forEach(modelContext.delete)
            inventoryProjectionNodes.forEach(modelContext.delete)
            inventoryProjectionEdges.forEach(modelContext.delete)
            if let inventoryProjectionState { modelContext.delete(inventoryProjectionState) }
            states.forEach(modelContext.delete)
            if let visibility { modelContext.delete(visibility) }
            return MirrorRebuildResult(
                deletedMirrorCount: mirrors.count,
                preservedOperationIDs: operations.filter { $0.state != .accepted }.map(\.operationID).sorted(),
                preservedReceiptCount: receipts.count, preservedConflictCount: conflicts.count)
        }
    }

    // MARK: Read repositories
}
