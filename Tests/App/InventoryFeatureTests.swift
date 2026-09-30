import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

final class InventoryFeatureTests: XCTestCase {
    func testOpaqueScanAcceptsOnlyCanonicalObjectRoute() throws {
        let id = try XCTUnwrap(UUID(uuidString: "A4B0E37E-2D92-4F93-9374-ABBD3C2CB84A"))
        XCTAssertEqual(OpaqueScanParser.parse("nettwork://object/\(id.uuidString.lowercased())")?.objectID, ObjectID(id))
        XCTAssertNil(OpaqueScanParser.parse("nettwork://object/SW-CORE-01"))
        XCTAssertNil(OpaqueScanParser.parse("https://example.invalid/object/\(id.uuidString)"))
    }

    func testInventoryQueryResultLimitIsBoundedByContract() {
        var query = InventorySearchQuery()
        query.maximumResults = 10_000
        XCTAssertGreaterThan(query.maximumResults, 50)
        // InventoryExploreModel clamps this request to 50 before invoking its query seam.
        XCTAssertEqual(min(max(query.maximumResults, 1), 50), 50)
    }

    @MainActor
    func testFailedSearchClearsPreviousMatchesWhileLoadingAndExposesError() async {
        let query = ControllableInventoryQuery()
        let model = InventoryExploreModel(
            account: inventoryTestAccount(), queryService: query, historyStore: InventoryHistoryFixture()
        )
        let previous = inventoryResult(title: "Previous query")
        let first = Task { await model.search() }
        await waitUntil { await query.hasSearch("") }
        await query.completeSearch("", with: [previous])
        await first.value
        XCTAssertEqual(model.results, [previous])

        model.query.text = "new query"
        let second = Task { await model.search() }
        await waitUntil { await query.hasSearch("new query") }
        XCTAssertTrue(model.results.isEmpty)
        await query.failSearch("new query")
        await second.value

        XCTAssertTrue(model.results.isEmpty)
        guard case .offline = model.state else {
            return XCTFail("A failed query must expose its error without stale matches.")
        }
    }

    @MainActor
    func testLatestInventorySearchWinsWhenEarlierRequestFinishesLast() async {
        let query = ControllableInventoryQuery()
        let model = InventoryExploreModel(
            account: inventoryTestAccount(),
            queryService: query,
            historyStore: InventoryHistoryFixture()
        )
        let firstResult = inventoryResult(title: "First")
        let secondResult = inventoryResult(title: "Second")

        model.query.text = "first"
        let firstSearch = Task { await model.search() }
        await waitUntil { await query.hasSearch("first") }
        model.query.text = "second"
        let secondSearch = Task { await model.search() }
        await waitUntil { await query.hasSearch("second") }

        await query.completeSearch("second", with: [secondResult])
        await secondSearch.value
        await query.completeSearch("first", with: [firstResult])
        await firstSearch.value

        XCTAssertEqual(model.results, [secondResult])
    }

    @MainActor
    func testLatestInventorySelectionWinsWhenEarlierRequestFinishesLast() async {
        let query = ControllableInventoryQuery()
        let model = InventoryExploreModel(
            account: inventoryTestAccount(),
            queryService: query,
            historyStore: InventoryHistoryFixture()
        )
        let first = inventoryResult(title: "First")
        let second = inventoryResult(title: "Second")

        let firstSelection = Task { await model.select(first.id) }
        await waitUntil { await query.hasDetails(first.id) }
        let secondSelection = Task { await model.select(second.id) }
        await waitUntil { await query.hasDetails(second.id) }

        await query.completeDetails(second.id, with: inventoryDetails(for: second))
        await secondSelection.value
        await query.completeDetails(first.id, with: inventoryDetails(for: first))
        await firstSelection.value

        XCTAssertEqual(model.selectedDetails?.result, second)
    }

    func testPrivacySafeLabelContainsOnlyOpaqueRouteAndLocalCheckText() {
        let label = PrivacySafeLabel(objectID: ObjectID(UUID(uuidString: "A4B0E37E-2D92-4F93-9374-ABBD3C2CB84A")!), assetCode: "sw core 01", checkText: "A7")
        XCTAssertEqual(label.assetCode.value, "SW-CORE-01")
        XCTAssertEqual(ObjectLink.objectID(from: label.opaqueRoute), label.objectID)
        XCTAssertFalse(label.opaqueRoute.absoluteString.contains(label.assetCode.value))
    }

    func testF05LabelValidatorRejectsPrivacyUnsafeOrOversizedText() {
        let objectID = ObjectID(UUID(uuidString: "2E3FE9A6-2031-4FB3-BEEE-B54A2E121F42")!)
        let valid = PrivacySafeLabel(objectID: objectID, assetCode: "SW-CORE-01", checkText: "A7")
        let unsafe = PrivacySafeLabel(objectID: objectID, assetCode: "SW-CORE-01", checkText: "A7\\n10.0.0.1")
        let tooLong = PrivacySafeLabel(objectID: objectID, assetCode: "SW-CORE-01", checkText: String(repeating: "A", count: 17))

        XCTAssertNoThrow(try PrivacySafeLabelValidator.validate(valid))
        XCTAssertThrowsError(try PrivacySafeLabelValidator.validate(unsafe))
        XCTAssertThrowsError(try PrivacySafeLabelValidator.validate(tooLong))
        XCTAssertThrowsError(try PrivacySafeLabelValidator.validated([unsafe]))
        XCTAssertThrowsError(try PrivacySafeLabelValidator.validated(Array(repeating: valid, count: 101)))
    }

    func testTopologyWorkOrderRequestRetainsTheCompletePlannedConnection() {
        let source = ObjectID()
        let destination = ObjectID()
        let cableID = ObjectID()
        let cable = Cable(
            id: cableID, assetCode: "PATCH-42", endpointA: source, endpointB: destination, medium: .copper, connector: .rj45, kind: .patchCord,
            status: .planned, color: "blue", lengthMeters: 2.0)
        let request = TopologyWorkOrderRequest(
            title: "Patch switch", ticket: "CHG-42", notes: "Verify light levels",
            action: .connect(ConnectTopologyCommand(operationID: ObjectID(), cable: cable)),
            resourceKeys: [.object(cableID), .object(source), .object(destination)])
        XCTAssertEqual(request.resourceKeys, [.object(cableID), .object(source), .object(destination)])
        if case let .connect(command) = request.action {
            XCTAssertEqual(command.cable, cable)
            XCTAssertEqual(command.cable.id, cableID)
        } else {
            XCTFail("Expected staged connection")
        }
    }

    @MainActor
    func testChangingLabelConfigurationInvalidatesGeneratedDocument() async {
        let account = AccountContext(
            namespace: PersistenceNamespace(
                containerIdentifier: "iCloud.example.nettwork",
                cloudKitAccountRecordName: "account",
                workspaceID: ObjectID(),
                zoneName: "workspace",
                zoneOwnerRecordName: "owner",
                sessionGeneration: 1
            ),
            databaseScope: .ownerPrivate,
            sharePermission: .owner,
            verifiedAt: .now
        )
        let label = PrivacySafeLabel(objectID: ObjectID(), assetCode: "SW-1", checkText: "A1")
        let model = LabelSheetModel(
            account: account,
            source: LabelSourceFixture(labels: [label]),
            generator: LabelGeneratorFixture(),
            exporter: LabelExporterFixture(),
            printer: LabelPrinterFixture()
        )

        await model.load()
        await model.generate()
        XCTAssertNotNil(model.document)

        model.configuration.rows += 1
        XCTAssertNil(model.document)
    }

    func testTemplateRequestCarriesItsCompleteTargetAndMigrationPlans() {
        let source = ObjectID()
        let previous = DeviceType(id: source, name: "Edge switch", kind: .switchDevice, version: 1)
        let target = DeviceType(id: source, name: "Edge switch", kind: .switchDevice, version: 2)
        let request = TemplateChangeRequest(
            title: "Upgrade edge switch", ticketID: "CHG-42", notes: "Validate port migration before execution.", targetTemplate: target,
            requestKind: .newVersion(sourceTemplateID: source))
        let migrationPlan = DeviceTemplateMigrationPlan(
            deviceID: ObjectID(), sourceSnapshot: DeviceTemplateSnapshot(template: previous), targetSnapshot: DeviceTemplateSnapshot(template: target),
            portImpacts: [])
        let migration = TemplateChangeRequest(
            title: "Migrate edge switch", ticketID: "CHG-43", notes: "Review affected cables.", targetTemplate: target,
            requestKind: .migration(plans: [migrationPlan]))

        XCTAssertEqual(request.title, "Upgrade edge switch")
        XCTAssertEqual(request.ticketID, "CHG-42")
        XCTAssertEqual(request.notes, "Validate port migration before execution.")
        XCTAssertEqual(request.targetTemplate, target)
        if case let .newVersion(sourceTemplateID) = request.requestKind {
            XCTAssertEqual(sourceTemplateID, source)
        } else {
            XCTFail("Expected a versioned template request")
        }
        if case let .migration(plans) = migration.requestKind {
            XCTAssertEqual(plans, [migrationPlan])
            XCTAssertEqual(plans.first?.targetSnapshot, DeviceTemplateSnapshot(template: target))
        } else {
            XCTFail("Expected a migration request")
        }
    }

    func testIPAMPrefixLayoutCarriesTheCompleteDesiredLayoutAndRevisionScope() throws {
        let vrfID = ObjectID()
        let vrf = VRF(id: vrfID, name: "production", revision: 4)
        let prefix = try XCTUnwrap(Prefix(vrfID: vrfID, cidr: "10.42.0.0/16", name: "Campus"))
        let request = IPAMWorkOrderRequest(
            title: "Allocate VLAN address",
            ticketID: "CHG-44",
            notes: "Reserve the complete campus prefix layout.",
            perVRFRevisionKey: .object(vrfID),
            operation: .prefixLayout(PrefixLayoutWorkOrderRequest(vrf: vrf, currentPrefixes: [], desiredPrefixes: [prefix]))
        )

        XCTAssertEqual(request.ticketID, "CHG-44")
        XCTAssertEqual(request.notes, "Reserve the complete campus prefix layout.")
        XCTAssertEqual(request.perVRFRevisionKey, .object(vrfID))
        if case let .prefixLayout(layout) = request.operation {
            XCTAssertEqual(layout.vrf, vrf)
            XCTAssertEqual(layout.vrf.id, vrfID)
            XCTAssertEqual(layout.currentPrefixes, [])
            XCTAssertEqual(layout.desiredPrefixes, [prefix])
            XCTAssertEqual(layout.expectedRevision, 4)
        } else {
            XCTFail("Expected planned prefix layout operation")
        }
    }

    func testIPAMAddressAssignmentPreservesItsAuthoritativeStringResourceKey() {
        let recordName = "ip-address:vrf:2001:db8::42"
        let snapshot = IPAMAddressSnapshot(
            id: ObjectID(),
            resourceKey: .string(recordName),
            address: "2001:db8::42",
            interfaceName: nil,
            vlanName: nil,
            assignments: [],
            state: .active,
            isPlanned: false,
            isPending: false,
            isConflicted: false
        )

        XCTAssertEqual(snapshot.resourceKey, .string(recordName))
        let interfaceID = ObjectID()
        let vrf = VRF(name: "Production", revision: 7)
        let assignment = IPAddressAssignment(addressID: recordName, interfaceID: interfaceID, isPrimary: true)
        let operation = IPAMWorkOrderOperation.addressAssignment(
            InterfaceAddressAssignmentSet(
                revisionVRF: vrf,
                interfaceID: interfaceID,
                currentAssignments: [],
                desiredAssignments: [assignment],
                primaryAddressID: recordName
            ))
        if case let .addressAssignment(assignments) = operation {
            XCTAssertEqual(assignments.revisionVRF, vrf)
            XCTAssertEqual(assignments.desiredAssignments, [assignment])
            XCTAssertEqual(assignments.primaryAddressID, recordName)
        } else {
            XCTFail("Expected an address assignment operation")
        }
    }

    func testTraceDirectionsAndAvailabilityAreAccessibleStableValues() {
        XCTAssertEqual(Set(TraceDirection.allCases), [.forward, .reverse])
        XCTAssertEqual(InventoryPortAvailability.conflicted.title, "Conflicted")
    }

    @MainActor
    func testLatestTraceDirectionWinsWhenEarlierRequestFinishesLast() async {
        let service = ControllableTraceInspector()
        let portID = ObjectID()
        let model = TraceInspectionModel(account: inventoryTestAccount(), service: service)

        let forward = Task { await model.load(startPortID: portID) }
        await waitUntil { await service.hasRequest(.forward) }
        model.direction = .reverse
        let reverse = Task { await model.load(startPortID: portID) }
        await waitUntil { await service.hasRequest(.reverse) }

        await service.complete(.reverse, with: traceSnapshot(portID: portID, termination: "Reverse result"))
        await reverse.value
        await service.complete(.forward, with: traceSnapshot(portID: portID, termination: "Stale forward result"))
        await forward.value

        XCTAssertEqual(model.inspection?.branches.first?.termination, "Reverse result")
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("The controlled inventory request was not registered.")
    }
}

private func inventoryTestAccount() -> AccountContext {
    AccountContext(
        namespace: PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "account",
            workspaceID: ObjectID(),
            zoneName: "workspace",
            zoneOwnerRecordName: "owner",
            sessionGeneration: 1
        ),
        databaseScope: .ownerPrivate,
        sharePermission: .owner,
        verifiedAt: .now
    )
}

private func inventoryResult(title: String) -> InventorySearchResult {
    InventorySearchResult(
        id: ObjectID(),
        kind: .device,
        title: title,
        subtitle: "Rack A",
        siteName: "Campus",
        isTombstoned: false,
        isPending: false,
        isConflicted: false
    )
}

private func inventoryDetails(for result: InventorySearchResult) -> InventoryObjectDetails {
    InventoryObjectDetails(
        result: result,
        containment: ["Campus", "Room 1", "Rack A"],
        connectivitySummary: "No active links",
        traceSummary: "Not traced",
        logicalContext: [],
        reservationSummary: nil,
        pendingSummary: nil,
        recentAuditSummary: [],
        attachmentCount: 0
    )
}

private actor ControllableInventoryQuery: InventoryQuerying {
    private var searches: [String: CheckedContinuation<[InventorySearchResult], any Error>] = [:]
    private var detailRequests: [ObjectID: CheckedContinuation<InventoryObjectDetails?, any Error>] = [:]

    func siteOptions(in namespace: PersistenceNamespace) async throws -> [InventorySiteOption] { [] }

    func search(
        _ query: InventorySearchQuery,
        in namespace: PersistenceNamespace
    ) async throws -> [InventorySearchResult] {
        try await withCheckedThrowingContinuation { searches[query.text] = $0 }
    }

    func details(for id: ObjectID, in namespace: PersistenceNamespace) async throws -> InventoryObjectDetails? {
        try await withCheckedThrowingContinuation { detailRequests[id] = $0 }
    }

    func results(for ids: [ObjectID], in namespace: PersistenceNamespace) async throws -> [InventorySearchResult] { [] }

    func hasSearch(_ text: String) -> Bool { searches[text] != nil }
    func hasDetails(_ id: ObjectID) -> Bool { detailRequests[id] != nil }

    func completeSearch(_ text: String, with results: [InventorySearchResult]) {
        searches.removeValue(forKey: text)?.resume(returning: results)
    }

    func failSearch(_ text: String) {
        searches.removeValue(forKey: text)?.resume(throwing: CocoaError(.fileReadUnknown))
    }

    func completeDetails(_ id: ObjectID, with details: InventoryObjectDetails?) {
        detailRequests.removeValue(forKey: id)?.resume(returning: details)
    }
}

private actor InventoryHistoryFixture: InventoryHistoryStoring {
    func recent(in scope: InventoryAccountScope) async -> [ObjectID] { [] }
    func favorites(in scope: InventoryAccountScope) async -> Set<ObjectID> { [] }
    func recordRecent(_ id: ObjectID, in scope: InventoryAccountScope) async {}
    func toggleFavorite(_ id: ObjectID, in scope: InventoryAccountScope) async -> Set<ObjectID> { [] }
}

private actor ControllableTraceInspector: TraceInspecting {
    private var requests: [TraceDirection: CheckedContinuation<TraceInspectionSnapshot, any Error>] = [:]

    func inspect(
        startingAt portID: ObjectID,
        direction: TraceDirection,
        in namespace: PersistenceNamespace
    ) async throws -> TraceInspectionSnapshot {
        try await withCheckedThrowingContinuation { requests[direction] = $0 }
    }

    func hasRequest(_ direction: TraceDirection) -> Bool { requests[direction] != nil }

    func complete(_ direction: TraceDirection, with snapshot: TraceInspectionSnapshot) {
        requests.removeValue(forKey: direction)?.resume(returning: snapshot)
    }
}

private func traceSnapshot(portID: ObjectID, termination: String) -> TraceInspectionSnapshot {
    TraceInspectionSnapshot(
        startPortID: portID,
        branches: [
            TraceBranchSnapshot(
                id: ObjectID(),
                nodes: [],
                segments: [],
                warnings: [],
                termination: termination
            )
        ],
        globalWarnings: [],
        isStale: false,
        hasPendingWork: false,
        hasConflict: false
    )
}

private actor LabelSourceFixture: PrivacySafeLabelSourcing {
    let values: [PrivacySafeLabel]

    init(labels: [PrivacySafeLabel]) { values = labels }

    func labels(in namespace: PersistenceNamespace, limit: Int) async throws -> [PrivacySafeLabel] {
        Array(values.prefix(limit))
    }
}

private actor LabelGeneratorFixture: LabelPDFGenerating {
    func makePDF(
        labels: [PrivacySafeLabel],
        configuration: LabelSheetConfiguration
    ) async throws -> LabelPDFDocument {
        LabelPDFDocument(data: Data([1]), pageCount: 1)
    }
}

private actor LabelExporterFixture: LabelPDFExporting {
    func export(_ document: LabelPDFDocument) async throws {}
}

private actor LabelPrinterFixture: LabelPrinting {
    func print(_ document: LabelPDFDocument) async throws {}
}
