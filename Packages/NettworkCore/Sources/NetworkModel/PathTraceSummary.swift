import Foundation

/// Bounded physical-trace metrics for inventory and other overview surfaces.
/// It deliberately omits nodes, segments, enrichment, warnings, dependencies,
/// and cache state carried by `RichTraceResult`.
public struct PathTraceSummary: Codable, Hashable, Sendable {
    public let exploredPathCount: Int
    public let longestSegmentCount: Int
    public let cycleCount: Int
    public let isTruncated: Bool

    public init(exploredPathCount: Int, longestSegmentCount: Int, cycleCount: Int, isTruncated: Bool) {
        self.exploredPathCount = exploredPathCount
        self.longestSegmentCount = longestSegmentCount
        self.cycleCount = cycleCount
        self.isTruncated = isTruncated
    }
}

extension DefaultPathTraceService {
    /// Traverses the physical graph without materializing path details. The
    /// adjacency list is built and sorted once, while the explicit DFS stack
    /// mutates one pair of path-local sets as branches are entered and left.
    public static func summarize(
        from startPortID: ObjectID,
        in topology: PhysicalTopology,
        limits: TraceTraversalLimits = .init()
    ) throws -> PathTraceSummary {
        try Task.checkCancellation()
        var knownPorts = Set<ObjectID>()
        var operationCount = 0
        for port in topology.ports {
            knownPorts.insert(port.id)
            try periodicCancellationCheck(&operationCount)
        }
        guard knownPorts.contains(startPortID) else { throw PathTraceError.unknownStartPort(startPortID) }
        let adjacency = try summaryAdjacency(for: topology)
        return try summarize(from: startPortID, adjacency: adjacency, limits: limits)
    }

    private struct SummarySegmentIdentity: Hashable {
        let id: ObjectID
        let kind: TraceSegmentKind
    }

    private struct SummaryFrame {
        let portID: ObjectID
        let incoming: SummarySegmentIdentity?
        var nextEdgeIndex = 0
        var didExploreEdge = false
    }

    private struct SummaryMetrics {
        var exploredPathCount = 0
        var longestSegmentCount = 0
        var cycleCount = 0
        var isTruncated = false
    }

    private static func summaryAdjacency(for topology: PhysicalTopology) throws -> [ObjectID: [TraceSegment]] {
        var result: [ObjectID: [TraceSegment]] = [:]
        var operationCount = 0
        for cable in topology.cables {
            result[cable.endpointA, default: []].append(
                TraceSegment(id: cable.id, kind: .cable, fromPortID: cable.endpointA, toPortID: cable.endpointB))
            result[cable.endpointB, default: []].append(
                TraceSegment(id: cable.id, kind: .cable, fromPortID: cable.endpointB, toPortID: cable.endpointA))
            try periodicCancellationCheck(&operationCount)
        }
        for link in topology.internalLinks {
            result[link.endpointA, default: []].append(
                TraceSegment(id: link.id, kind: .internalLink, fromPortID: link.endpointA, toPortID: link.endpointB))
            result[link.endpointB, default: []].append(
                TraceSegment(id: link.id, kind: .internalLink, fromPortID: link.endpointB, toPortID: link.endpointA))
            try periodicCancellationCheck(&operationCount)
        }
        for portID in Array(result.keys) {
            result[portID] = try cancellableSortedEdges(result[portID, default: []])
            try periodicCancellationCheck(&operationCount)
        }
        try Task.checkCancellation()
        return result
    }

    private static func summarize(
        from startPortID: ObjectID,
        adjacency: [ObjectID: [TraceSegment]],
        limits: TraceTraversalLimits
    ) throws -> PathTraceSummary {
        var stack = [SummaryFrame(portID: startPortID, incoming: nil)]
        var visitedPorts: Set<ObjectID> = [startPortID]
        var usedSegments = Set<SummarySegmentIdentity>()
        var metrics = SummaryMetrics()
        var operationCount = 0

        while !stack.isEmpty {
            try periodicCancellationCheck(&operationCount)
            let depth = stack.count - 1
            if depth >= limits.maximumSegmentsPerPath {
                guard recordSummaryPath(segmentCount: depth, cycle: false, limits: limits, metrics: &metrics) else { break }
                metrics.isTruncated = true
                popSummaryFrame(from: &stack, visitedPorts: &visitedPorts, usedSegments: &usedSegments)
                continue
            }

            let frameIndex = stack.count - 1
            let edges = adjacency[stack[frameIndex].portID, default: []]
            let nextEdge = try nextAvailableEdge(
                in: edges,
                frame: &stack[frameIndex],
                usedSegments: usedSegments,
                operationCount: &operationCount
            )

            guard let edge = nextEdge else {
                if !stack[frameIndex].didExploreEdge {
                    guard recordSummaryPath(segmentCount: depth, cycle: false, limits: limits, metrics: &metrics) else { break }
                }
                popSummaryFrame(from: &stack, visitedPorts: &visitedPorts, usedSegments: &usedSegments)
                continue
            }

            stack[frameIndex].didExploreEdge = true
            let identity = SummarySegmentIdentity(id: edge.id, kind: edge.kind)
            if visitedPorts.contains(edge.toPortID) {
                guard recordSummaryPath(segmentCount: depth + 1, cycle: true, limits: limits, metrics: &metrics) else { break }
                continue
            }
            visitedPorts.insert(edge.toPortID)
            usedSegments.insert(identity)
            stack.append(SummaryFrame(portID: edge.toPortID, incoming: identity))
        }

        try Task.checkCancellation()
        return PathTraceSummary(
            exploredPathCount: metrics.exploredPathCount,
            longestSegmentCount: metrics.longestSegmentCount,
            cycleCount: metrics.cycleCount,
            isTruncated: metrics.isTruncated
        )
    }

    private static func recordSummaryPath(
        segmentCount: Int,
        cycle: Bool,
        limits: TraceTraversalLimits,
        metrics: inout SummaryMetrics
    ) -> Bool {
        guard metrics.exploredPathCount < limits.maximumPaths else {
            metrics.isTruncated = true
            return false
        }
        metrics.exploredPathCount += 1
        metrics.longestSegmentCount = max(metrics.longestSegmentCount, segmentCount)
        if cycle { metrics.cycleCount += 1 }
        return true
    }

    private static func nextAvailableEdge(
        in edges: [TraceSegment],
        frame: inout SummaryFrame,
        usedSegments: Set<SummarySegmentIdentity>,
        operationCount: inout Int
    ) throws -> TraceSegment? {
        while frame.nextEdgeIndex < edges.count {
            let edge = edges[frame.nextEdgeIndex]
            frame.nextEdgeIndex += 1
            try periodicCancellationCheck(&operationCount)
            let identity = SummarySegmentIdentity(id: edge.id, kind: edge.kind)
            if !usedSegments.contains(identity) { return edge }
        }
        return nil
    }

    private static func popSummaryFrame(
        from stack: inout [SummaryFrame],
        visitedPorts: inout Set<ObjectID>,
        usedSegments: inout Set<SummarySegmentIdentity>
    ) {
        let frame = stack.removeLast()
        guard let incoming = frame.incoming else { return }
        visitedPorts.remove(frame.portID)
        usedSegments.remove(incoming)
    }

    private static func cancellableSortedEdges(_ edges: [TraceSegment]) throws -> [TraceSegment] {
        guard edges.count > 1 else { return edges }
        var source = edges
        var destination = edges
        var width = 1
        var comparisonCount = 0
        while width < source.count {
            var lower = 0
            while lower < source.count {
                let middle = min(lower + width, source.count)
                let upper = min(lower + width * 2, source.count)
                var left = lower
                var right = middle
                for output in lower..<upper {
                    try periodicCancellationCheck(&comparisonCount)
                    if left < middle, right >= upper || summaryEdgeLess(source[left], source[right]) {
                        destination[output] = source[left]
                        left += 1
                    } else {
                        destination[output] = source[right]
                        right += 1
                    }
                }
                lower = upper
            }
            swap(&source, &destination)
            width *= 2
        }
        return source
    }

    private static func summaryEdgeLess(_ lhs: TraceSegment, _ rhs: TraceSegment) -> Bool {
        if lhs.kind.rawValue != rhs.kind.rawValue { return lhs.kind.rawValue < rhs.kind.rawValue }
        if lhs.id != rhs.id { return lhs.id < rhs.id }
        return lhs.toPortID < rhs.toPortID
    }

    private static func periodicCancellationCheck(_ count: inout Int) throws {
        count += 1
        if count.isMultiple(of: 64) { try Task.checkCancellation() }
    }
}
