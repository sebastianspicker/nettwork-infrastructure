import Foundation
import SwiftData
import WorkspaceChangeControl

enum SwiftDataPredicateBatching {
    /// SQLite-backed SwiftData predicates reserve variables for namespace and
    /// other filters; 900 keys stays below the common 999-variable ceiling.
    static let maximumKeysPerFetch = 900

    static func chunks(_ keys: some Sequence<String>) -> [[String]] {
        let sorted = Array(Set(keys)).sorted()
        guard !sorted.isEmpty else { return [] }
        return stride(from: 0, to: sorted.count, by: maximumKeysPerFetch).map { start in
            Array(sorted[start..<min(start + maximumKeysPerFetch, sorted.count)])
        }
    }
}

enum SwiftDataPredicateFetchKind: Hashable, Sendable {
    case projectionNode
    case dependencyFrontier
    case incidentSource
    case incidentTarget
    case searchEntry
}

typealias SwiftDataPredicateFetchObserver = (SwiftDataPredicateFetchKind, Int) -> Void

extension SwiftDataPersistenceStore {
    func inventoryProjectionNodeModels(
        storageKeys: some Sequence<String>,
        namespace: PersistenceNamespace,
        observer: SwiftDataPredicateFetchObserver? = nil
    ) throws -> [LocalInventoryProjectionNodeModel] {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        var result: [LocalInventoryProjectionNodeModel] = []
        for keys in SwiftDataPredicateBatching.chunks(storageKeys) {
            observer?(.projectionNode, keys.count)
            let descriptor = FetchDescriptor<LocalInventoryProjectionNodeModel>(
                predicate: #Predicate {
                    $0.namespaceKey == namespaceKey && keys.contains($0.storageKey)
                })
            result.append(contentsOf: try modelContext.fetch(descriptor))
        }
        return result.sorted { $0.storageKey < $1.storageKey }
    }

    func inventoryProjectionEdges(
        sourceKeys: some Sequence<String>,
        in namespace: PersistenceNamespace,
        observer: SwiftDataPredicateFetchObserver? = nil
    ) throws -> [LocalInventoryProjectionEdgeModel] {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        var result: [LocalInventoryProjectionEdgeModel] = []
        for keys in SwiftDataPredicateBatching.chunks(sourceKeys) {
            observer?(.dependencyFrontier, keys.count)
            let descriptor = FetchDescriptor<LocalInventoryProjectionEdgeModel>(
                predicate: #Predicate {
                    $0.namespaceKey == namespaceKey && keys.contains($0.sourceKey)
                })
            result.append(contentsOf: try modelContext.fetch(descriptor))
        }
        return result.sorted { $0.storageKey < $1.storageKey }
    }

    func inventoryProjectionEdges(
        incidentTo keys: some Sequence<String>,
        in namespace: PersistenceNamespace,
        observer: SwiftDataPredicateFetchObserver? = nil
    ) throws -> [LocalInventoryProjectionEdgeModel] {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        let chunks = SwiftDataPredicateBatching.chunks(keys)
        var byStorageKey: [String: LocalInventoryProjectionEdgeModel] = [:]
        for keyChunk in chunks {
            observer?(.incidentSource, keyChunk.count)
            let sourceDescriptor = FetchDescriptor<LocalInventoryProjectionEdgeModel>(
                predicate: #Predicate {
                    $0.namespaceKey == namespaceKey && keyChunk.contains($0.sourceKey)
                })
            for edge in try modelContext.fetch(sourceDescriptor) { byStorageKey[edge.storageKey] = edge }
            observer?(.incidentTarget, keyChunk.count)
            let targetDescriptor = FetchDescriptor<LocalInventoryProjectionEdgeModel>(
                predicate: #Predicate {
                    $0.namespaceKey == namespaceKey && keyChunk.contains($0.targetKey)
                })
            for edge in try modelContext.fetch(targetDescriptor) { byStorageKey[edge.storageKey] = edge }
        }
        return byStorageKey.values.sorted { $0.storageKey < $1.storageKey }
    }

    func inventorySearchIndexModels(
        objectIDValues: some Sequence<String>,
        in namespace: PersistenceNamespace,
        observer: SwiftDataPredicateFetchObserver? = nil
    ) throws -> [LocalInventorySearchIndexModel] {
        let namespaceKey = PersistenceNamespaceKey.value(for: namespace)
        var result: [LocalInventorySearchIndexModel] = []
        for values in SwiftDataPredicateBatching.chunks(objectIDValues) {
            observer?(.searchEntry, values.count)
            let descriptor = FetchDescriptor<LocalInventorySearchIndexModel>(
                predicate: #Predicate {
                    $0.namespaceKey == namespaceKey && values.contains($0.objectIDValue)
                })
            result.append(contentsOf: try modelContext.fetch(descriptor))
        }
        return result.sorted { $0.storageKey < $1.storageKey }
    }
}
