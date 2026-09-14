import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

extension SwiftDataPersistenceStore {
    func replaceInventoryProjectionComponent(
        dirtyKeys: Set<String>, changedRecords: [LocalMirrorRecord],
        materialization: InventorySearchIndexBuilder.Materialization, in namespace: PersistenceNamespace
    ) throws {
        guard let state = try inventoryProjectionStateModel(matching: PersistenceNamespaceKey.value(for: namespace)) else {
            throw PersistenceStoreError.inventoryProjectionIncomplete
        }
        state.isComplete = false
        state.updatedAt = .now
        let edgeDelta = try replaceInventoryProjectionEdges(
            dirtyKeys: dirtyKeys,
            materialization: materialization, namespace: namespace)
        let nodeDelta = try replaceInventoryProjectionNodes(
            changedRecords: changedRecords,
            materialization: materialization, namespace: namespace)
        let entryDelta = try replaceInventorySearchEntries(
            dirtyKeys: dirtyKeys,
            changedRecords: changedRecords, materialization: materialization, namespace: namespace)
        try storeInventoryProjectionCounts(
            state, edgeDelta: edgeDelta, nodeDelta: nodeDelta,
            entryDelta: entryDelta)
    }

    private func replaceInventoryProjectionEdges(
        dirtyKeys: Set<String>,
        materialization: InventorySearchIndexBuilder.Materialization, namespace: PersistenceNamespace
    ) throws -> Int {
        let deletedEdges = Dictionary(
            uniqueKeysWithValues: try inventoryProjectionEdges(incidentTo: dirtyKeys, in: namespace)
                .map { ($0.storageKey, $0) })
        deletedEdges.values.forEach(modelContext.delete)
        var edgeDelta = -deletedEdges.count
        for edge in materialization.edges where dirtyKeys.contains(edge.source.description) || dirtyKeys.contains(edge.target.description) {
            modelContext.insert(
                LocalInventoryProjectionEdgeModel(
                    namespace: namespace,
                    sourceKey: edge.source.description, targetKey: edge.target.description, kind: edge.kind))
            edgeDelta += 1
        }
        return edgeDelta
    }

    private func replaceInventoryProjectionNodes(
        changedRecords: [LocalMirrorRecord],
        materialization: InventorySearchIndexBuilder.Materialization, namespace: PersistenceNamespace
    ) throws -> Int {
        let derivedNodeKeys = try InventorySearchIndexBuilder.derivedNodeKeys(for: changedRecords)
        var replacementNodes = Dictionary(
            materialization.nodes
                .filter { derivedNodeKeys.contains($0.resourceKey) }
                .map { ($0.resourceKey.description, $0) }, uniquingKeysWith: { current, _ in current })
        var nodeDelta = 0
        for record in changedRecords where !record.isTombstone {
            replacementNodes[record.resourceKey.description] = record
        }
        let storageKeys = derivedNodeKeys.map { inventoryProjectionNodeStorageKey($0, in: namespace) }
        let existingNodes = Dictionary(
            uniqueKeysWithValues: try inventoryProjectionNodeModels(storageKeys: storageKeys, namespace: namespace)
                .map { ($0.storageKey, $0) })
        for resourceKey in derivedNodeKeys.sorted() {
            let resourceDescription = resourceKey.description
            let storageKey = inventoryProjectionNodeStorageKey(resourceKey, in: namespace)
            if let existing = existingNodes[storageKey] {
                modelContext.delete(existing)
                nodeDelta -= 1
            }
            if let replacement = replacementNodes[resourceDescription] {
                modelContext.insert(try LocalInventoryProjectionNodeModel(record: replacement))
                nodeDelta += 1
            }
        }
        return nodeDelta
    }

    private func replaceInventorySearchEntries(
        dirtyKeys: Set<String>, changedRecords: [LocalMirrorRecord],
        materialization: InventorySearchIndexBuilder.Materialization, namespace: PersistenceNamespace
    ) throws -> Int {
        let resourceKeys = Set(changedRecords.map(\.resourceKey)).union(
            try inventoryProjectionRecords(keys: dirtyKeys, namespace: namespace).map(\.resourceKey))
        let objectIDs = resourceKeys.map(inventorySearchObjectIDValue)
        let deletedModels = try inventorySearchIndexModels(objectIDValues: objectIDs, in: namespace)
        deletedModels.forEach(modelContext.delete)
        var entryDelta = -deletedModels.count
        for record in materialization.entries where dirtyKeys.contains(record.resourceKey.description) {
            modelContext.insert(try LocalInventorySearchIndexModel(record: record))
            entryDelta += 1
        }
        return entryDelta
    }

    private func inventorySearchObjectIDValue(_ resourceKey: ResourceKey) -> String {
        switch resourceKey {
        case .object(let value): value.description
        case .string(let value): InventorySearchIndexBuilder.stableObjectID(value).description
        }
    }

    private func storeInventoryProjectionCounts(
        _ state: LocalInventoryProjectionStateModel, edgeDelta: Int,
        nodeDelta: Int, entryDelta: Int
    ) throws {
        let nextNodeCount = state.nodeCount + nodeDelta
        let nextEdgeCount = state.edgeCount + edgeDelta
        let nextEntryCount = state.entryCount + entryDelta
        guard nextNodeCount >= 0, nextEdgeCount >= 0, nextEntryCount >= 0 else {
            throw PersistenceStoreError.inventoryProjectionIncomplete
        }
        guard nextNodeCount <= InventorySearchIndexBuilder.maximumDerivedNodes else {
            throw PersistenceStoreError.inventoryProjectionNodeCapacityExceeded(nextNodeCount)
        }
        guard nextEdgeCount <= InventorySearchIndexBuilder.maximumDerivedEdges else {
            throw PersistenceStoreError.inventorySearchIndexCapacityExceeded(nextEdgeCount)
        }
        guard nextEntryCount <= InventorySearchIndexBuilder.maximumEntries else {
            throw PersistenceStoreError.inventorySearchIndexCapacityExceeded(nextEntryCount)
        }
        state.nodeCount = nextNodeCount
        state.edgeCount = nextEdgeCount
        state.entryCount = nextEntryCount
        state.isComplete = true
        state.updatedAt = .now
    }

    func visibleInventoryMirrorRecords(in namespace: PersistenceNamespace) throws -> [LocalMirrorRecord] {
        try mirrorModels(namespaceKey: PersistenceNamespaceKey.value(for: namespace))
            .map { try decodeMirror($0, namespace: namespace) }
            .filter { try isVisibleToFeatureProjection($0, in: namespace) }
    }

    func inventorySearchStorageKey(
        _ identity: InventorySearchIndexBuilder.IndexIdentity,
        in namespace: PersistenceNamespace
    ) -> String {
        PersistenceNamespaceKey.storageKey(
            namespace: namespace,
            identity: "inventory-search:\(identity.kind):\(identity.objectID.description)")
    }

    func inventorySearchIndexModel(matching storageKey: String) throws -> LocalInventorySearchIndexModel? {
        let descriptor = FetchDescriptor<LocalInventorySearchIndexModel>(predicate: #Predicate { $0.storageKey == storageKey })
        return try modelContext.fetch(descriptor).first
    }

    func inventorySearchIndexModels(namespaceKey: String) throws -> [LocalInventorySearchIndexModel] {
        let descriptor = FetchDescriptor<LocalInventorySearchIndexModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    /// Used solely by `inventoryProjectionNeedsRepair` during open.
    func inventorySearchIndexCount(in namespace: PersistenceNamespace) throws -> Int {
        let key = PersistenceNamespaceKey.value(for: namespace)
        let descriptor = FetchDescriptor<LocalInventorySearchIndexModel>(predicate: #Predicate { $0.namespaceKey == key })
        return try modelContext.fetchCount(descriptor)
    }

    func inventorySearchIndexModels(
        resourceKey: ResourceKey, in namespace: PersistenceNamespace
    ) throws -> [LocalInventorySearchIndexModel] {
        let objectID: ObjectID
        switch resourceKey {
        case let .object(value): objectID = value
        case let .string(value): objectID = InventorySearchIndexBuilder.stableObjectID(value)
        }
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let objectIDValue = objectID.description
        let descriptor = FetchDescriptor<LocalInventorySearchIndexModel>(
            predicate: #Predicate {
                $0.namespaceKey == namespaceKey && $0.objectIDValue == objectIDValue
            })
        return try modelContext.fetch(descriptor)
    }

    func inventoryProjectionStateModel(matching namespaceKey: String) throws -> LocalInventoryProjectionStateModel? {
        let descriptor = FetchDescriptor<LocalInventoryProjectionStateModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor).first
    }

    func inventoryProjectionNodeStorageKey(_ resourceKey: ResourceKey, in namespace: PersistenceNamespace) -> String {
        PersistenceNamespaceKey.storageKey(namespace: namespace, identity: "inventory-projection-node:\(resourceKey.description)")
    }

    func inventoryProjectionNodeModel(matching storageKey: String) throws -> LocalInventoryProjectionNodeModel? {
        let descriptor = FetchDescriptor<LocalInventoryProjectionNodeModel>(predicate: #Predicate { $0.storageKey == storageKey })
        return try modelContext.fetch(descriptor).first
    }

    func inventoryProjectionNodeModel(
        resourceDescription: String, in namespace: PersistenceNamespace
    ) throws -> LocalInventoryProjectionNodeModel? {
        let storageKey = PersistenceNamespaceKey.storageKey(
            namespace: namespace,
            identity: "inventory-projection-node:\(resourceDescription)")
        return try inventoryProjectionNodeModel(matching: storageKey)
    }

    func inventoryProjectionNodeModels(namespaceKey: String) throws -> [LocalInventoryProjectionNodeModel] {
        let descriptor = FetchDescriptor<LocalInventoryProjectionNodeModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    /// Used solely by `inventoryProjectionNeedsRepair` during open.
    func inventoryProjectionNodeCount(in namespace: PersistenceNamespace) throws -> Int {
        let key = PersistenceNamespaceKey.value(for: namespace)
        let descriptor = FetchDescriptor<LocalInventoryProjectionNodeModel>(predicate: #Predicate { $0.namespaceKey == key })
        return try modelContext.fetchCount(descriptor)
    }

    func inventoryProjectionEdgeStorageKey(
        _ edge: InventorySearchIndexBuilder.DependencyEdge,
        in namespace: PersistenceNamespace
    ) -> String {
        PersistenceNamespaceKey.storageKey(
            namespace: namespace,
            identity: "inventory-projection-edge:\(edge.kind):\(edge.source.description):\(edge.target.description)"
        )
    }

    func inventoryProjectionEdgeModel(matching storageKey: String) throws -> LocalInventoryProjectionEdgeModel? {
        let descriptor = FetchDescriptor<LocalInventoryProjectionEdgeModel>(predicate: #Predicate { $0.storageKey == storageKey })
        return try modelContext.fetch(descriptor).first
    }

    func inventoryProjectionEdges(sourceKey: String, in namespace: PersistenceNamespace) throws -> [LocalInventoryProjectionEdgeModel] {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let descriptor = FetchDescriptor<LocalInventoryProjectionEdgeModel>(
            predicate: #Predicate {
                $0.namespaceKey == namespaceKey && $0.sourceKey == sourceKey
            })
        return try modelContext.fetch(descriptor)
    }

    func inventoryProjectionEdges(incidentTo key: String, in namespace: PersistenceNamespace) throws -> [LocalInventoryProjectionEdgeModel] {
        let outgoing = try inventoryProjectionEdges(sourceKey: key, in: namespace)
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let descriptor = FetchDescriptor<LocalInventoryProjectionEdgeModel>(
            predicate: #Predicate {
                $0.namespaceKey == namespaceKey && $0.targetKey == key
            })
        return outgoing + (try modelContext.fetch(descriptor))
    }

    func inventoryProjectionEdgeModels(namespaceKey: String) throws -> [LocalInventoryProjectionEdgeModel] {
        let descriptor = FetchDescriptor<LocalInventoryProjectionEdgeModel>(predicate: #Predicate { $0.namespaceKey == namespaceKey })
        return try modelContext.fetch(descriptor)
    }

    /// Used solely by `inventoryProjectionNeedsRepair` during open.
    func inventoryProjectionEdgeCount(in namespace: PersistenceNamespace) throws -> Int {
        let key = PersistenceNamespaceKey.value(for: namespace)
        let descriptor = FetchDescriptor<LocalInventoryProjectionEdgeModel>(predicate: #Predicate { $0.namespaceKey == key })
        return try modelContext.fetchCount(descriptor)
    }

    func overwrite(
        _ model: LocalInventorySearchIndexModel, with record: LocalInventorySearchRecord
    ) throws {
        let replacement = try LocalInventorySearchIndexModel(record: record)
        model.namespaceKey = replacement.namespaceKey
        model.objectIDValue = replacement.objectIDValue
        model.resourceKeyData = replacement.resourceKeyData
        model.kind = replacement.kind
        model.title = replacement.title
        model.subtitle = replacement.subtitle
        model.siteName = replacement.siteName
        model.siteMembershipTokens = replacement.siteMembershipTokens
        model.searchText = replacement.searchText
        model.searchTermsData = replacement.searchTermsData
        model.isPending = replacement.isPending
    }

    func decodeInventorySearchRecord(
        _ model: LocalInventorySearchIndexModel, namespace: PersistenceNamespace
    ) throws -> LocalInventorySearchRecord {
        guard model.namespaceKey == PersistenceNamespaceKey.value(for: namespace),
            let uuid = UUID(uuidString: model.objectIDValue)
        else {
            throw PersistenceStoreError.malformedStoredValue("inventory search identity")
        }
        let resourceKey = try PersistenceCoding.decode(ResourceKey.self, from: model.resourceKeyData)
        let searchTerms = try PersistenceCoding.decode([String].self, from: model.searchTermsData)
        let siteIDs = Set(model.siteMembershipTokens.split(separator: "|").compactMap { UUID(uuidString: String($0)).map { ObjectID($0) } })
        return LocalInventorySearchRecord(
            namespace: namespace, objectID: ObjectID(uuid),
            resourceKey: resourceKey, kind: model.kind, title: model.title, subtitle: model.subtitle,
            siteName: model.siteName, siteIDs: siteIDs, searchTerms: searchTerms, isPending: model.isPending)
    }

    func isInfrastructureRecordType(_ type: String) -> Bool {
        type.hasPrefix("NettworkWorkspaceTransfer") || type == "NettworkWorkspace"
    }

    func overwrite(
        _ model: LocalCloudRecordNameIdentityModel, with identity: LocalCloudRecordNameIdentity
    ) throws {
        model.resourceKeyData = try PersistenceCoding.encode(identity.resourceKey)
        model.recordType = identity.recordType
        model.schemaVersion = identity.schemaVersion
        model.systemFields = identity.systemFields
        model.changeTag = identity.changeTag
    }

    func validateCloudRecordNameIdentity(
        _ identity: LocalCloudRecordNameIdentity,
        in namespace: PersistenceNamespace
    ) throws {
        guard identity.namespace == namespace,
            !identity.recordName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            identity.recordName.lengthOfBytes(using: .utf8) <= 240,
            !identity.recordType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            identity.schemaVersion > 0, !identity.systemFields.isEmpty,
            !identity.changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw PersistenceStoreError.invalidCloudRecordNameIdentity(identity.recordName)
        }
    }

    func decodeCloudRecordNameIdentity(
        _ model: LocalCloudRecordNameIdentityModel,
        namespace: PersistenceNamespace
    ) throws -> LocalCloudRecordNameIdentity {
        let resourceKey = try PersistenceCoding.decode(ResourceKey.self, from: model.resourceKeyData)
        let identity = LocalCloudRecordNameIdentity(
            namespace: namespace, recordName: model.recordName,
            resourceKey: resourceKey, recordType: model.recordType, schemaVersion: model.schemaVersion,
            systemFields: model.systemFields, changeTag: model.changeTag)
        try validateCloudRecordNameIdentity(identity, in: namespace)
        let expectedStorageKey = PersistenceNamespaceKey.storageKey(
            namespace: namespace,
            identity: "cloud-record-name-identity:\(model.recordName)")
        guard model.namespaceKey == PersistenceNamespaceKey.value(for: namespace),
            model.storageKey == expectedStorageKey
        else {
            throw PersistenceStoreError.malformedStoredValue("cloud record-name identity")
        }
        return identity
    }
}
