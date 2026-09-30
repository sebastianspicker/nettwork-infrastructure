import Foundation

public enum DefaultPathTraceService {
    /// Compatibility contract: this preserves the original physical-only
    /// result shape and includes every documented cable/link regardless of
    /// operational status. Use `traceRich` for warnings and context.
    public static func trace(from startPortID: ObjectID, in topology: PhysicalTopology) throws -> [PhysicalPath] {
        guard topology.ports.contains(where: { $0.id == startPortID }) else { throw PathTraceError.unknownStartPort(startPortID) }
        return walk(current: startPortID, edges: makeEdges(topology), visitedPorts: [startPortID], usedSegments: [], segments: [])
    }

    /// Direction is defined by the selected source port. Since every physical
    /// segment is bidirectional, tracing from either endpoint is the reverse
    /// inspection of the same graph, with independently deterministic branch
    /// ordering.
    public static func traceRich(
        from startPortID: ObjectID, in topology: PhysicalTopology, enrichment: TraceEnrichment = .init(), limits: TraceTraversalLimits = .init()
    ) throws -> RichTraceResult {
        guard topology.ports.contains(where: { $0.id == startPortID }) else { throw PathTraceError.unknownStartPort(startPortID) }
        let resolver = TraceContextResolver(topology: topology, enrichment: enrichment)
        var state = RichWalkState(limits: limits)
        let paths = walkRich(
            current: startPortID, graph: makeRichGraph(topology), resolver: resolver, visitedPorts: [startPortID], usedSegments: [], segments: [], warnings: [],
            state: &state)
        let pathAndNodeWarnings = paths.flatMap(\.warnings) + paths.flatMap { $0.nodes.flatMap(\.warnings) }
        let aggregateWarnings = sortedWarnings(Set(pathAndNodeWarnings).union(state.didReachPathLimit ? [.pathLimitReached(limits.maximumPaths)] : []))
        let dependencies = Set(
            paths.flatMap { path in
                path.nodes.flatMap { node in
                    var values: [TraceResource] = [.port(node.id)]
                    if let device = node.device { values.append(.device(device.id)) }
                    if let rack = node.rack {
                        values.append(.rack(rack.id))
                        values.append(contentsOf: rack.locationPath.map { .location($0.id) })
                    }
                    for interface in node.interfaces {
                        values.append(.interface(interface.id))
                        values.append(contentsOf: interface.addresses.map(TraceResource.ipAddress))
                        values.append(contentsOf: interface.vlans.map { .vlan($0.id) })
                    }
                    return values
                } + path.segments.map { $0.segment.kind == .cable ? .cable($0.segment.id) : .internalLink($0.segment.id) }
            })
        return RichTraceResult(
            startPortID: startPortID, topologyRevision: topology.revision, enrichmentRevision: enrichment.revision, paths: paths, warnings: aggregateWarnings,
            dependencies: dependencies)
    }

    public static func traceRich(
        to endPortID: ObjectID, in topology: PhysicalTopology, enrichment: TraceEnrichment = .init(), limits: TraceTraversalLimits = .init()
    ) throws -> RichTraceResult {
        try traceRich(from: endPortID, in: topology, enrichment: enrichment, limits: limits)
    }

    private static func makeEdges(_ topology: PhysicalTopology) -> [ObjectID: [TraceSegment]] {
        var result: [ObjectID: [TraceSegment]] = [:]
        for cable in topology.cables {
            append(TraceSegment(id: cable.id, kind: .cable, fromPortID: cable.endpointA, toPortID: cable.endpointB), to: &result)
            append(TraceSegment(id: cable.id, kind: .cable, fromPortID: cable.endpointB, toPortID: cable.endpointA), to: &result)
        }
        for link in topology.internalLinks {
            append(TraceSegment(id: link.id, kind: .internalLink, fromPortID: link.endpointA, toPortID: link.endpointB), to: &result)
            append(TraceSegment(id: link.id, kind: .internalLink, fromPortID: link.endpointB, toPortID: link.endpointA), to: &result)
        }
        return result
    }

    private static func append(_ edge: TraceSegment, to dictionary: inout [ObjectID: [TraceSegment]]) {
        dictionary[edge.fromPortID, default: []].append(edge)
        dictionary[edge.fromPortID]?.sort { edgeSortKey($0) < edgeSortKey($1) }
    }

    private static func edgeSortKey(_ edge: TraceSegment) -> (String, ObjectID, ObjectID) { (edge.kind.rawValue, edge.id, edge.toPortID) }
    private struct SegmentIdentity: Hashable {
        let id: ObjectID
        let kind: TraceSegmentKind
    }

    private static func walk(
        current: ObjectID, edges: [ObjectID: [TraceSegment]], visitedPorts: [ObjectID], usedSegments: Set<SegmentIdentity>, segments: [TraceSegment]
    ) -> [PhysicalPath] {
        let candidates = edges[current, default: []].filter { !usedSegments.contains(SegmentIdentity(id: $0.id, kind: $0.kind)) }
        guard !candidates.isEmpty else { return [PhysicalPath(ports: visitedPorts, segments: segments)] }
        return candidates.flatMap { edge in
            let identity = SegmentIdentity(id: edge.id, kind: edge.kind)
            if visitedPorts.contains(edge.toPortID) { return [PhysicalPath(ports: visitedPorts, segments: segments + [edge], stoppedByCycle: true)] }
            return walk(
                current: edge.toPortID, edges: edges, visitedPorts: visitedPorts + [edge.toPortID], usedSegments: usedSegments.union([identity]),
                segments: segments + [edge])
        }
    }

    private static func makeRichGraph(_ topology: PhysicalTopology) -> [ObjectID: [RichGraphEdge]] {
        let cableByID = Dictionary(topology.cables.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tombstones = Set(topology.tombstones.map { traceResource(for: $0) })
        return makeEdges(topology).mapValues {
            $0.map { edge in
                let resource: TraceResource = edge.kind == .cable ? .cable(edge.id) : .internalLink(edge.id)
                return RichGraphEdge(segment: edge, cable: cableByID[edge.id], isTombstoned: tombstones.contains(resource))
            }
        }
    }

    private static func traceResource(for tombstone: TopologyTombstone) -> TraceResource {
        switch tombstone.kind {
        case .device, .module: .device(tombstone.id)
        case .port: .port(tombstone.id)
        case .cable: .cable(tombstone.id)
        case .internalLink: .internalLink(tombstone.id)
        }
    }

    private static func walkRich(
        current: ObjectID, graph: [ObjectID: [RichGraphEdge]], resolver: TraceContextResolver, visitedPorts: [ObjectID], usedSegments: Set<SegmentIdentity>,
        segments: [RichTraceSegment],
        warnings: [TraceWarning], state: inout RichWalkState
    ) -> [RichPhysicalPath] {
        guard state.emittedPathCount < state.limits.maximumPaths else {
            state.didReachPathLimit = true
            return []
        }
        if segments.count >= state.limits.maximumSegmentsPerPath {
            return emitRichPath(
                portIDs: visitedPorts, segments: segments, termination: .segmentLimit,
                warnings: warnings + [.segmentLimitReached(state.limits.maximumSegmentsPerPath)], resolver: resolver, state: &state)
        }
        let candidates = graph[current, default: []].filter { !usedSegments.contains(SegmentIdentity(id: $0.segment.id, kind: $0.segment.kind)) }
        guard !candidates.isEmpty else {
            return emitTerminalPath(current: current, visitedPorts: visitedPorts, segments: segments, warnings: warnings, resolver: resolver, state: &state)
        }
        let branchWarnings = candidates.count > 1 ? warnings + [.ambiguousContinuation(portID: current, count: candidates.count)] : warnings
        return candidates.flatMap {
            continueRichPath(
                edge: $0, graph: graph, resolver: resolver, visitedPorts: visitedPorts, usedSegments: usedSegments, segments: segments,
                warnings: branchWarnings, state: &state)
        }
    }

    private static func emitTerminalPath(
        current: ObjectID, visitedPorts: [ObjectID], segments: [RichTraceSegment], warnings: [TraceWarning], resolver: TraceContextResolver,
        state: inout RichWalkState
    ) -> [RichPhysicalPath] {
        let passive = resolver.isPassivePort(current)
        let termination: TraceTermination = passive ? .incompletePassiveMapping(portID: current) : .endpoint(portID: current)
        let terminalWarnings = passive ? warnings + [.incompletePassiveMapping(portID: current)] : warnings
        return emitRichPath(portIDs: visitedPorts, segments: segments, termination: termination, warnings: terminalWarnings, resolver: resolver, state: &state)
    }

    private static func continueRichPath(
        edge: RichGraphEdge, graph: [ObjectID: [RichGraphEdge]], resolver: TraceContextResolver, visitedPorts: [ObjectID], usedSegments: Set<SegmentIdentity>,
        segments: [RichTraceSegment], warnings: [TraceWarning], state: inout RichWalkState
    ) -> [RichPhysicalPath] {
        let resource = traceResource(for: edge.segment)
        let richSegment = RichTraceSegment(segment: edge.segment, cable: edge.cable.map(TraceCableContext.init))
        var nextWarnings = warnings
        if edge.isTombstoned {
            return emitResourceTermination(
                resource, portIDs: visitedPorts, segments: segments + [richSegment], warnings: nextWarnings, resolver: resolver, state: &state)
        }
        if edge.cable?.status == .unavailable { nextWarnings.append(.unavailableCable(edge.segment.id)) }
        return continueRichPathIfPossible(
            edge: edge, graph: graph, resolver: resolver, visitedPorts: visitedPorts, usedSegments: usedSegments, segments: segments + [richSegment],
            warnings: nextWarnings, resource: resource, state: &state)
    }

    private static func continueRichPathIfPossible(
        edge: RichGraphEdge, graph: [ObjectID: [RichGraphEdge]], resolver: TraceContextResolver, visitedPorts: [ObjectID], usedSegments: Set<SegmentIdentity>,
        segments: [RichTraceSegment], warnings: [TraceWarning], resource: TraceResource, state: inout RichWalkState
    ) -> [RichPhysicalPath] {
        let nextPort = edge.segment.toPortID
        guard resolver.hasPort(nextPort) else {
            return emitMissingPort(nextPort, portIDs: visitedPorts, segments: segments, warnings: warnings, resolver: resolver, state: &state)
        }
        if resolver.isTombstonedPort(nextPort) {
            return emitResourceTermination(.port(nextPort), portIDs: visitedPorts, segments: segments, warnings: warnings, resolver: resolver, state: &state)
        }
        if visitedPorts.contains(nextPort) {
            return emitCycle(nextPort, resource: resource, portIDs: visitedPorts, segments: segments, warnings: warnings, resolver: resolver, state: &state)
        }
        let identity = SegmentIdentity(id: edge.segment.id, kind: edge.segment.kind)
        return walkRich(
            current: nextPort, graph: graph, resolver: resolver, visitedPorts: visitedPorts + [nextPort], usedSegments: usedSegments.union([identity]),
            segments: segments, warnings: warnings, state: &state)
    }

    private static func emitResourceTermination(
        _ resource: TraceResource, portIDs: [ObjectID], segments: [RichTraceSegment], warnings: [TraceWarning], resolver: TraceContextResolver,
        state: inout RichWalkState
    ) -> [RichPhysicalPath] {
        emitRichPath(
            portIDs: portIDs, segments: segments, termination: .tombstonedResource(resource), warnings: warnings + [.tombstonedResource(resource)],
            resolver: resolver, state: &state)
    }

    private static func emitMissingPort(
        _ portID: ObjectID, portIDs: [ObjectID], segments: [RichTraceSegment], warnings: [TraceWarning], resolver: TraceContextResolver,
        state: inout RichWalkState
    ) -> [RichPhysicalPath] {
        emitRichPath(
            portIDs: portIDs, segments: segments, termination: .missingPort(portID), warnings: warnings + [.missingPort(portID)], resolver: resolver,
            state: &state)
    }

    private static func emitCycle(
        _ portID: ObjectID, resource: TraceResource, portIDs: [ObjectID], segments: [RichTraceSegment], warnings: [TraceWarning],
        resolver: TraceContextResolver, state: inout RichWalkState
    ) -> [RichPhysicalPath] {
        emitRichPath(
            portIDs: portIDs, segments: segments, termination: .cycle(portID: portID), warnings: warnings + [.cycle(portID: portID, through: resource)],
            resolver: resolver, state: &state)
    }

    private static func traceResource(for segment: TraceSegment) -> TraceResource {
        segment.kind == .cable ? .cable(segment.id) : .internalLink(segment.id)
    }

    private static func emitRichPath(
        portIDs: [ObjectID], segments: [RichTraceSegment], termination: TraceTermination, warnings: [TraceWarning], resolver: TraceContextResolver,
        state: inout RichWalkState
    ) -> [RichPhysicalPath] {
        guard state.emittedPathCount < state.limits.maximumPaths else {
            state.didReachPathLimit = true
            return []
        }
        state.emittedPathCount += 1
        return [
            RichPhysicalPath(nodes: portIDs.compactMap(resolver.node), segments: segments, termination: termination, warnings: sortedWarnings(Set(warnings)))
        ]
    }

    private static func sortedWarnings(_ warnings: Set<TraceWarning>) -> [TraceWarning] { warnings.sorted { $0.sortKey < $1.sortKey } }
}
