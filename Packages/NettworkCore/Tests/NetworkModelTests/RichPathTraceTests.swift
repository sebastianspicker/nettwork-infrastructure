import XCTest

@testable import NetworkModel

final class RichPathTraceTests: XCTestCase {
    func testRichCanonicalTraceCarriesTopologyAndLogicalContext() throws {
        let fixture = NetworkModelTestData.richPassThroughTrace()
        let result = try DefaultPathTraceService.traceRich(from: fixture.startPortID, in: fixture.topology, enrichment: fixture.enrichment)
        XCTAssertEqual(result, try DefaultPathTraceService.traceRich(from: fixture.startPortID, in: fixture.topology, enrichment: fixture.enrichment))
        let path = try XCTUnwrap(result.paths.first)
        XCTAssertEqual(path.ports.first, fixture.startPortID)
        XCTAssertEqual(path.ports.last, fixture.endPortID)
        XCTAssertEqual(path.segments.map(\.segment.kind), [.cable, .internalLink, .cable, .internalLink, .cable])
        XCTAssertEqual(path.nodes.last?.rack?.assetCode, "RACK-101-A")
        XCTAssertEqual(path.nodes.last?.interfaces.first?.addresses, ["192.0.2.10"])
        XCTAssertEqual(path.nodes.last?.interfaces.first?.vlans.map(\.number), [120])
    }

    func testReverseTraceIsTheSameRouteInReverse() throws {
        let fixture = NetworkModelTestData.richPassThroughTrace()
        let forward = try DefaultPathTraceService.traceRich(from: fixture.startPortID, in: fixture.topology, enrichment: fixture.enrichment)
        let reverse = try DefaultPathTraceService.traceRich(to: fixture.endPortID, in: fixture.topology, enrichment: fixture.enrichment)
        XCTAssertEqual(reverse.paths.first?.ports, forward.paths.first.map { Array($0.ports.reversed()) })
    }

    func testBranchBrokenAndUnavailableRecordsProduceOrderedWarnings() throws {
        var fixture = NetworkModelTestData.passThroughTopology()
        fixture.topology.cables[0].status = .unavailable
        fixture.topology.cables.append(
            Cable(
                id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000100")!), assetCode: "BROKEN", endpointA: fixture.startPortID,
                endpointB: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000199")!), medium: .copper, connector: .rj45, kind: .fixed,
                status: .installed))
        let result = try DefaultPathTraceService.traceRich(from: fixture.startPortID, in: fixture.topology)
        XCTAssertEqual(result.paths.count, 2)
        XCTAssertTrue(result.warnings.contains(.ambiguousContinuation(portID: fixture.startPortID, count: 2)))
        XCTAssertTrue(result.warnings.contains(.unavailableCable(fixture.topology.cables[0].id)))
        XCTAssertTrue(result.warnings.contains(.missingPort(ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000199")!))))
        XCTAssertEqual(result.paths.first?.termination, .missingPort(ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000199")!)))
    }

    func testPassiveGapCycleAndTraversalLimitAreExplicit() throws {
        var fixture = NetworkModelTestData.passThroughTopology()
        fixture.topology.internalLinks.removeFirst()
        let gap = try DefaultPathTraceService.traceRich(from: fixture.startPortID, in: fixture.topology)
        XCTAssertEqual(gap.paths.first?.termination, .incompletePassiveMapping(portID: fixture.topology.cables[0].endpointB))

        fixture = NetworkModelTestData.passThroughTopology()
        fixture.topology.internalLinks.append(
            InternalLink(id: ObjectID(UUID(uuidString: "00000000-0000-0000-0000-000000000210")!), endpointA: fixture.startPortID, endpointB: fixture.endPortID))
        let cyclic = try DefaultPathTraceService.traceRich(from: fixture.startPortID, in: fixture.topology)
        XCTAssertTrue(cyclic.paths.contains(where: \.stoppedByCycle))

        let bounded = try DefaultPathTraceService.traceRich(
            from: fixture.startPortID, in: fixture.topology, limits: TraceTraversalLimits(maximumSegmentsPerPath: 2, maximumPaths: 8))
        XCTAssertTrue(bounded.paths.contains(where: { $0.termination == .segmentLimit }))
    }

    func testTombstonedSegmentIsReportedWithoutFollowingStaleDocumentation() throws {
        var fixture = NetworkModelTestData.passThroughTopology()
        let cableID = fixture.topology.cables[0].id
        fixture.topology.tombstones.append(TopologyTombstone(id: cableID, kind: .cable, deletedAt: .distantPast))
        let result = try DefaultPathTraceService.traceRich(from: fixture.startPortID, in: fixture.topology)
        XCTAssertEqual(result.paths.first?.termination, .tombstonedResource(.cable(cableID)))
        XCTAssertTrue(result.warnings.contains(.tombstonedResource(.cable(cableID))))
    }

    func testDuplexFiberAndIncrementalCacheDependencies() throws {
        let fixture = NetworkModelTestData.duplexFiberTopology()
        let result = try DefaultPathTraceService.traceRich(from: fixture.startPortID, in: fixture.topology)
        XCTAssertEqual(result.paths.first?.nodes.first?.fiberMode, .duplex)
        XCTAssertEqual(result.paths.first?.segments.first?.cable?.medium, .fiber)
        var cache = IncrementalTraceCache()
        cache.store(result)
        let key = TraceCacheKey(startPortID: fixture.startPortID, topologyRevision: fixture.topology.revision)
        XCTAssertEqual(cache.result(for: key), result)
        XCTAssertEqual(cache.invalidate(resources: [.port(fixture.startPortID)]), [key])
        XCTAssertNil(cache.result(for: key))
        cache.store(result)
        XCTAssertEqual(cache.invalidate(topologyRevision: fixture.topology.revision + 1), [key])
    }

    func testSummaryMatchesLegacyPathMetricsWithoutMaterializingRichDetails() throws {
        var fixture = NetworkModelTestData.passThroughTopology()
        fixture.topology.internalLinks.append(
            InternalLink(id: ObjectID(), endpointA: fixture.startPortID, endpointB: fixture.endPortID))
        let legacy = try DefaultPathTraceService.trace(from: fixture.startPortID, in: fixture.topology)
        let summary = try DefaultPathTraceService.summarize(
            from: fixture.startPortID,
            in: fixture.topology,
            limits: TraceTraversalLimits(maximumSegmentsPerPath: 32, maximumPaths: 128)
        )

        XCTAssertEqual(summary.exploredPathCount, legacy.count)
        XCTAssertEqual(summary.longestSegmentCount, legacy.map(\.segments.count).max())
        XCTAssertEqual(summary.cycleCount, legacy.filter(\.stoppedByCycle).count)
        XCTAssertFalse(summary.isTruncated)
    }

    func testSummaryReportsPathAndSegmentLimits() throws {
        let fixture = NetworkModelTestData.passThroughTopology()
        let segmentLimited = try DefaultPathTraceService.summarize(
            from: fixture.startPortID,
            in: fixture.topology,
            limits: TraceTraversalLimits(maximumSegmentsPerPath: 2, maximumPaths: 128)
        )
        XCTAssertEqual(segmentLimited.exploredPathCount, 1)
        XCTAssertEqual(segmentLimited.longestSegmentCount, 2)
        XCTAssertTrue(segmentLimited.isTruncated)

        var branched = fixture.topology
        for offset in 0..<4 {
            branched.cables.append(
                Cable(
                    assetCode: AssetCode("BRANCH-\(offset)"),
                    endpointA: fixture.startPortID,
                    endpointB: ObjectID(),
                    medium: .copper,
                    connector: .rj45,
                    kind: .patchCord,
                    status: .installed
                ))
        }
        let pathLimited = try DefaultPathTraceService.summarize(
            from: fixture.startPortID,
            in: branched,
            limits: TraceTraversalLimits(maximumSegmentsPerPath: 512, maximumPaths: 2)
        )
        XCTAssertEqual(pathLimited.exploredPathCount, 2)
        XCTAssertTrue(pathLimited.isTruncated)
    }

    func testSummaryMarksAnExactDefaultSegmentBoundaryAsTruncated() throws {
        let topology = linearTopology(segmentCount: TraceTraversalLimits().maximumSegmentsPerPath)
        let summary = try DefaultPathTraceService.summarize(from: topology.ports[0].id, in: topology)
        XCTAssertEqual(summary.exploredPathCount, 1)
        XCTAssertEqual(summary.longestSegmentCount, 512)
        XCTAssertTrue(summary.isTruncated)
    }

    func testSummaryObservesCancellationBeforeGraphConstruction() async {
        let fixture = NetworkModelTestData.passThroughTopology()
        let error = await Task { () -> (any Error)? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try DefaultPathTraceService.summarize(from: fixture.startPortID, in: fixture.topology)
                return nil
            } catch {
                return error
            }
        }.value
        XCTAssertTrue(error is CancellationError)
    }

    private func linearTopology(segmentCount: Int) -> PhysicalTopology {
        let deviceID = ObjectID()
        let ports = (0...segmentCount).map { offset in
            Port(id: ObjectID(), deviceID: deviceID, label: "P\(offset)", medium: .copper, connector: .rj45)
        }
        let cables = (0..<segmentCount).map { offset in
            Cable(
                assetCode: AssetCode("C\(offset)"),
                endpointA: ports[offset].id,
                endpointB: ports[offset + 1].id,
                medium: .copper,
                connector: .rj45,
                kind: .patchCord,
                status: .installed
            )
        }
        return PhysicalTopology(ports: ports, cables: cables)
    }
}
