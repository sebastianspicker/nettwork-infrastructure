import Foundation
import NetworkModel
import WorkspaceChangeControl

extension InventorySearchIndexBuilder {
    static func materialize(records: [LocalMirrorRecord], namespace: PersistenceNamespace) throws -> Materialization {
        try Task.checkCancellation()
        let projection = try Projection(records: records)
        let entries = try build(records: records, namespace: namespace)
        let edges = try materializationEdges(for: projection)
        let nodes = try canonicalNodeRecords(projection: projection, namespace: namespace)
        try validateMaterializationCapacity(edges: edges, nodes: nodes)
        return Materialization(entries: entries, nodes: nodes, edges: sortedEdges(edges))
    }

    static func validateMaterializationCapacity(edges: Set<DependencyEdge>, nodes: [LocalMirrorRecord]) throws {
        guard edges.count <= maximumDerivedEdges else {
            throw PersistenceStoreError.inventorySearchIndexCapacityExceeded(edges.count)
        }
        guard nodes.count <= maximumDerivedNodes else {
            throw PersistenceStoreError.inventoryProjectionNodeCapacityExceeded(nodes.count)
        }
    }

    static func sortedEdges(_ edges: Set<DependencyEdge>) -> [DependencyEdge] {
        edges.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source < rhs.source }
            if lhs.target != rhs.target { return lhs.target < rhs.target }
            return lhs.kind < rhs.kind
        }
    }

    static func dirtyClosure(from seeds: Set<String>, edges: [DependencyEdge]) throws -> Set<String> {
        let adjacency = Dictionary(grouping: edges.filter { $0.kind.hasPrefix("dirty.") }, by: { $0.source.description })
        return try traverseDirtyClosure(seeds: seeds, adjacency: adjacency)
    }

    static func traverseDirtyClosure(
        seeds: Set<String>, adjacency: [String: [DependencyEdge]]
    ) throws -> Set<String> {
        var visited = seeds
        var frontier = Array(seeds)
        var visits = 0
        while let source = frontier.popLast() {
            try visitDirtyEdges(adjacency[source, default: []], visited: &visited, frontier: &frontier, visits: &visits)
        }
        return visited
    }

    static func visitDirtyEdges(
        _ edges: [DependencyEdge], visited: inout Set<String>,
        frontier: inout [String], visits: inout Int
    ) throws {
        for edge in edges {
            visits += 1
            try validateDirtyTraversal(visits: visits, visitedCount: visited.count)
            if visited.insert(edge.target.description).inserted {
                try validateDirtyTraversal(visits: visits, visitedCount: visited.count)
                frontier.append(edge.target.description)
            }
        }
    }

    static func validateDirtyTraversal(visits: Int, visitedCount: Int) throws {
        guard visits <= maximumDependencyVisits else {
            throw PersistenceStoreError.inventoryProjectionTraversalExceeded(visits)
        }
        guard visitedCount <= maximumIncrementalMutations else {
            throw PersistenceStoreError.inventoryProjectionTraversalExceeded(visitedCount)
        }
    }
}
