import Foundation
import NetworkModel
import WorkspaceChangeControl

public struct OutboxReplayPlan: Sendable {
    public let ordered: [OutboxOperation]
    public let deferredOperationIDs: Set<ObjectID>
    public let cyclicOperationIDs: Set<ObjectID>
    /// Explicit plus shared-resource prerequisites of each eligible operation.
    public let dependencies: [ObjectID: Set<ObjectID>]
    public init(
        ordered: [OutboxOperation], deferredOperationIDs: Set<ObjectID>, cyclicOperationIDs: Set<ObjectID>,
        dependencies: [ObjectID: Set<ObjectID>] = [:]
    ) {
        self.ordered = ordered
        self.deferredOperationIDs = deferredOperationIDs
        self.cyclicOperationIDs = cyclicOperationIDs
        self.dependencies = dependencies
    }
}

/// Produces a deterministic topological order. Operations sharing an affected
/// resource are serialized by creation time even when callers omitted an edge.
public enum OutboxDependencyPlanner {
    public static func plan(_ operations: [OutboxOperation], at date: Date) -> OutboxReplayPlan {
        plan(operations, acceptedIDs: acceptedOperationIDs(in: operations), at: date)
    }

    /// `acceptedIDs` lets callers omit decoded accepted history and pass only the IDs.
    public static func plan(_ operations: [OutboxOperation], acceptedIDs accepted: Set<ObjectID>, at date: Date) -> OutboxReplayPlan {
        let eligible = eligibleOperations(in: operations, at: date)
        let byID = Dictionary(uniqueKeysWithValues: eligible.map { ($0.operationID, $0) })
        var dependencies = initialDependencies(for: eligible)
        let deferred = deferredOperationIDs(eligible: eligible, byID: byID, dependencies: &dependencies, accepted: accepted)
        let pending = topologicalOrder(eligible: eligible, byID: byID, dependencies: dependencies, deferred: deferred)
        return OutboxReplayPlan(ordered: pending.ordered, deferredOperationIDs: deferred, cyclicOperationIDs: pending.cyclic, dependencies: dependencies)
    }

    private static func eligibleOperations(in operations: [OutboxOperation], at date: Date) -> [OutboxOperation] {
        operations.filter { operation in
            switch operation.state {
            case .pending, .retryScheduled: return operation.nextRetryAt.map { $0 <= date } ?? true
            case .uploading, .conflicted, .poisoned, .accepted: return false
            }
        }.sorted { lhs, rhs in
            lhs.createdAt == rhs.createdAt ? lhs.operationID < rhs.operationID : lhs.createdAt < rhs.createdAt
        }
    }

    private static func initialDependencies(for eligible: [OutboxOperation]) -> [ObjectID: Set<ObjectID>] {
        var dependencies = Dictionary(uniqueKeysWithValues: eligible.map { ($0.operationID, Set($0.dependencyOperationIDs)) })
        for index in eligible.indices {
            for otherIndex in eligible.indices where otherIndex < index {
                let later = eligible[index]
                let earlier = eligible[otherIndex]
                if !later.resourceKeys.isDisjoint(with: earlier.resourceKeys) {
                    dependencies[later.operationID, default: []].insert(earlier.operationID)
                }
            }
        }
        return dependencies
    }

    private static func acceptedOperationIDs(in operations: [OutboxOperation]) -> Set<ObjectID> {
        Set(operations.filter { $0.state == .accepted && $0.receipt != nil }.map(\.operationID))
    }

    private static func deferredOperationIDs(
        eligible: [OutboxOperation], byID: [ObjectID: OutboxOperation], dependencies: inout [ObjectID: Set<ObjectID>], accepted: Set<ObjectID>
    ) -> Set<ObjectID> {
        var deferred = Set<ObjectID>()
        for operation in eligible where !operation.dependencyOperationIDs.allSatisfy({ byID[$0] != nil || accepted.contains($0) }) {
            deferred.insert(operation.operationID)
        }
        var addedDeferred = true
        while addedDeferred {
            addedDeferred = false
            for operation in eligible where !deferred.contains(operation.operationID) {
                if !dependencies[operation.operationID, default: []].isDisjoint(with: deferred) {
                    deferred.insert(operation.operationID)
                    addedDeferred = true
                }
            }
        }
        return deferred
    }

    private static func topologicalOrder(
        eligible: [OutboxOperation], byID: [ObjectID: OutboxOperation], dependencies: [ObjectID: Set<ObjectID>], deferred: Set<ObjectID>
    ) -> (ordered: [OutboxOperation], cyclic: Set<ObjectID>) {
        var pending = Set(eligible.map(\.operationID)).subtracting(deferred)
        var ordered: [OutboxOperation] = []
        while let nextID = pending.filter({ dependencies[$0, default: []].isDisjoint(with: pending) }).sorted(by: stableOrder).first {
            pending.remove(nextID)
            if let operation = byID[nextID] { ordered.append(operation) }
        }
        return (ordered, pending)
    }

    private static func stableOrder(_ lhs: ObjectID, _ rhs: ObjectID) -> Bool { lhs < rhs }
}
