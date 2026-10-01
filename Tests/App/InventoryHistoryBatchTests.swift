import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork
@testable import WorkspaceServices

final class InventoryHistoryBatchTests: XCTestCase {
    func testInventoryTraceSummaryPreservesCompleteWordingAndMarksPartialResults() {
        let complete = PathTraceSummary(exploredPathCount: 3, longestSegmentCount: 7, cycleCount: 1, isTruncated: false)
        XCTAssertEqual(MirrorProjection.inventoryTraceDescription(complete), "3 path(s), up to 7 segment(s), 1 cycle warning(s)")

        let partial = PathTraceSummary(exploredPathCount: 128, longestSegmentCount: 512, cycleCount: 2, isTruncated: true)
        let partialDescription = MirrorProjection.inventoryTraceDescription(partial)
        XCTAssertTrue(partialDescription.hasPrefix("Partial trace"))
        XCTAssertTrue(partialDescription.contains("limit reached"))
    }

    @MainActor
    func testHistoryUsesOneBatchAndReconstructsFavoriteAndRecentOrder() async {
        let first = makeInventoryResult(title: "First")
        let second = makeInventoryResult(title: "Second")
        let tombstoned = makeInventoryResult(title: "Deleted", isTombstoned: true)
        let missing = ObjectID()
        let query = InventoryBatchQuery(rows: [first, second, tombstoned])
        let history = SeededInventoryHistory(
            recents: [second.id, missing, tombstoned.id, second.id, first.id],
            favorites: [first.id, second.id]
        )
        let model = InventoryExploreModel(account: makeInventoryAccount(), queryService: query, historyStore: history)

        await model.loadHistory()

        let expectedFavorites = [first, second].sorted { $0.id < $1.id }
        let batchCallCount = await query.batchCallCount()
        let detailsCallCount = await query.detailsCallCount()
        let requestedIDs = await query.requestedIDs()
        XCTAssertEqual(model.favoriteResults, expectedFavorites)
        XCTAssertEqual(model.recentResults, [second, first])
        XCTAssertEqual(batchCallCount, 1)
        XCTAssertEqual(detailsCallCount, 0)
        XCTAssertEqual(requestedIDs, expectedFavorites.map(\.id) + [missing, tombstoned.id])
    }

    @MainActor
    func testLatestSameAccountHistoryRefreshWins() async {
        let first = makeInventoryResult(title: "Recent")
        let second = makeInventoryResult(title: "Favorite")
        let query = ControllableHistoryQuery()
        let history = MutableInventoryHistory(recents: [first.id])
        let model = InventoryExploreModel(account: makeInventoryAccount(), queryService: query, historyStore: history)

        let initialLoad = Task { await model.loadHistory() }
        await waitUntil { await query.requestCount() == 1 }
        let favoriteLoad = Task { await model.toggleFavorite(second.id) }
        await waitUntil { await query.requestCount() == 2 }

        await query.completeRequest(at: 1, with: [second, first])
        await favoriteLoad.value
        await query.completeRequest(at: 0, with: [first])
        await initialLoad.value

        XCTAssertEqual(model.favoriteResults, [second])
        XCTAssertEqual(model.recentResults, [first])
    }

    @MainActor
    private func waitUntil(_ condition: @escaping () async -> Bool) async {
        for _ in 0..<100 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("The controlled history request was not registered.")
    }
}

private actor InventoryBatchQuery: InventoryQuerying {
    private let rows: [ObjectID: InventorySearchResult]
    private var batches: [[ObjectID]] = []
    private var detailCalls = 0

    init(rows: [InventorySearchResult]) {
        self.rows = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    func siteOptions(in namespace: PersistenceNamespace) async throws -> [InventorySiteOption] { [] }
    func search(_ query: InventorySearchQuery, in namespace: PersistenceNamespace) async throws -> [InventorySearchResult] { [] }
    func results(for ids: [ObjectID], in namespace: PersistenceNamespace) async throws -> [InventorySearchResult] {
        batches.append(ids)
        return ids.compactMap { rows[$0] }.filter { !$0.isTombstoned }
    }
    func details(for id: ObjectID, in namespace: PersistenceNamespace) async throws -> InventoryObjectDetails? {
        detailCalls += 1
        return nil
    }
    func batchCallCount() -> Int { batches.count }
    func detailsCallCount() -> Int { detailCalls }
    func requestedIDs() -> [ObjectID] { batches.last ?? [] }
}

private actor SeededInventoryHistory: InventoryHistoryStoring {
    private let storedRecents: [ObjectID]
    private let storedFavorites: Set<ObjectID>

    init(recents: [ObjectID], favorites: Set<ObjectID>) {
        storedRecents = recents
        storedFavorites = favorites
    }

    func recent(in scope: InventoryAccountScope) async -> [ObjectID] { storedRecents }
    func favorites(in scope: InventoryAccountScope) async -> Set<ObjectID> { storedFavorites }
    func recordRecent(_ id: ObjectID, in scope: InventoryAccountScope) async {}
    func toggleFavorite(_ id: ObjectID, in scope: InventoryAccountScope) async -> Set<ObjectID> { storedFavorites }
}

private actor ControllableHistoryQuery: InventoryQuerying {
    private var requests: [CheckedContinuation<[InventorySearchResult], any Error>?] = []

    func siteOptions(in namespace: PersistenceNamespace) async throws -> [InventorySiteOption] { [] }
    func search(_ query: InventorySearchQuery, in namespace: PersistenceNamespace) async throws -> [InventorySearchResult] { [] }
    func results(for ids: [ObjectID], in namespace: PersistenceNamespace) async throws -> [InventorySearchResult] {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    func details(for id: ObjectID, in namespace: PersistenceNamespace) async throws -> InventoryObjectDetails? { nil }
    func requestCount() -> Int { requests.count }
    func completeRequest(at index: Int, with rows: [InventorySearchResult]) {
        requests[index]?.resume(returning: rows)
        requests[index] = nil
    }
}

private actor MutableInventoryHistory: InventoryHistoryStoring {
    private var storedRecents: [ObjectID]
    private var storedFavorites = Set<ObjectID>()

    init(recents: [ObjectID]) { storedRecents = recents }

    func recent(in scope: InventoryAccountScope) async -> [ObjectID] { storedRecents }
    func favorites(in scope: InventoryAccountScope) async -> Set<ObjectID> { storedFavorites }
    func recordRecent(_ id: ObjectID, in scope: InventoryAccountScope) async {
        storedRecents.removeAll { $0 == id }
        storedRecents.insert(id, at: 0)
    }
    func toggleFavorite(_ id: ObjectID, in scope: InventoryAccountScope) async -> Set<ObjectID> {
        if !storedFavorites.insert(id).inserted { storedFavorites.remove(id) }
        return storedFavorites
    }
}

private func makeInventoryAccount() -> AccountContext {
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

private func makeInventoryResult(title: String, isTombstoned: Bool = false) -> InventorySearchResult {
    InventorySearchResult(
        id: ObjectID(),
        kind: .device,
        title: title,
        subtitle: "Rack A",
        siteName: "Campus",
        isTombstoned: isTombstoned,
        isPending: false,
        isConflicted: false
    )
}
