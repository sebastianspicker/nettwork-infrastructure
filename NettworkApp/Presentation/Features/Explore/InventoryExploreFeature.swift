import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

enum InventoryPresentationState: Equatable {
    case loading
    case ready
    case empty
    case offline(String)
    case pending(String)
    case conflict(String)
    case quarantined(String)
    case permissionDenied(String)
    case unavailable(String)
}

enum InventoryObjectKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case site, room, rack, device, port, cable, address, interface
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbolName: String {
        switch self {
        case .site, .room: "building.2"
        case .rack: "server.rack"
        case .device: "cpu"
        case .port: "rectangle.portrait.and.arrow.forward"
        case .cable: "cable.connector"
        case .address: "network"
        case .interface: "point.3.connected.trianglepath.dotted"
        }
    }
}

struct InventorySearchQuery: Equatable, Sendable {
    var text = ""
    var kinds = Set<InventoryObjectKind>()
    var siteID: ObjectID?
    var maximumResults = 50
}

struct InventorySiteOption: Identifiable, Equatable, Sendable {
    let id: ObjectID
    let title: String
}

struct InventorySearchResult: Identifiable, Equatable, Sendable {
    let id: ObjectID
    let kind: InventoryObjectKind
    let title: String
    let subtitle: String
    let siteName: String?
    let searchTerms: [String]
    let isTombstoned: Bool
    let isPending: Bool
    let isConflicted: Bool

    init(
        id: ObjectID,
        kind: InventoryObjectKind,
        title: String,
        subtitle: String,
        siteName: String?,
        searchTerms: [String] = [],
        isTombstoned: Bool,
        isPending: Bool,
        isConflicted: Bool
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.siteName = siteName
        self.searchTerms = searchTerms
        self.isTombstoned = isTombstoned
        self.isPending = isPending
        self.isConflicted = isConflicted
    }
}

struct InventoryObjectDetails: Equatable, Sendable {
    let result: InventorySearchResult
    let containment: [String]
    let connectivitySummary: String
    let traceSummary: String
    let logicalContext: [String]
    let reservationSummary: String?
    let pendingSummary: String?
    let recentAuditSummary: [String]
    let attachmentCount: Int
}

struct InventoryAccountScope: Hashable, Sendable {
    let accountRecordName: String
    let workspaceID: ObjectID
    let sessionGeneration: UInt64

    init(account: AccountContext) {
        accountRecordName = account.namespace.cloudKitAccountRecordName
        workspaceID = account.namespace.workspaceID
        sessionGeneration = account.namespace.sessionGeneration
    }
}

protocol InventoryQuerying: Sendable {
    func siteOptions(in namespace: PersistenceNamespace) async throws -> [InventorySiteOption]
    func search(_ query: InventorySearchQuery, in namespace: PersistenceNamespace) async throws -> [InventorySearchResult]
    func results(for ids: [ObjectID], in namespace: PersistenceNamespace) async throws -> [InventorySearchResult]
    func details(for id: ObjectID, in namespace: PersistenceNamespace) async throws -> InventoryObjectDetails?
}

protocol InventoryHistoryStoring: Sendable {
    func recent(in scope: InventoryAccountScope) async -> [ObjectID]
    func favorites(in scope: InventoryAccountScope) async -> Set<ObjectID>
    func recordRecent(_ id: ObjectID, in scope: InventoryAccountScope) async
    func toggleFavorite(_ id: ObjectID, in scope: InventoryAccountScope) async -> Set<ObjectID>
}

@MainActor
@Observable
final class InventoryExploreModel {
    private let queryService: any InventoryQuerying
    private let historyStore: any InventoryHistoryStoring
    private var searchGeneration: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var historyGeneration: UInt64 = 0
    private(set) var account: AccountContext
    private(set) var state: InventoryPresentationState = .loading
    var query = InventorySearchQuery()
    private(set) var results: [InventorySearchResult] = []
    private(set) var siteOptions: [InventorySiteOption] = []
    private(set) var selectedDetails: InventoryObjectDetails?
    private(set) var favorites = Set<ObjectID>()
    private(set) var recents: [ObjectID] = []
    private(set) var favoriteResults: [InventorySearchResult] = []
    private(set) var recentResults: [InventorySearchResult] = []

    init(account: AccountContext, queryService: any InventoryQuerying, historyStore: any InventoryHistoryStoring) {
        self.account = account
        self.queryService = queryService
        self.historyStore = historyStore
    }

    func loadHistory() async {
        let scope = InventoryAccountScope(account: account)
        historyGeneration &+= 1
        let generation = historyGeneration
        async let storedRecents = historyStore.recent(in: scope)
        async let storedFavorites = historyStore.favorites(in: scope)
        let (loadedRecents, loadedFavorites) = await (storedRecents, storedFavorites)
        guard isCurrentHistory(generation, scope: scope) else { return }
        recents = loadedRecents
        favorites = loadedFavorites
        await refreshHistoryResults(in: scope, generation: generation)
    }

    func loadSiteOptions() async {
        let scope = InventoryAccountScope(account: account)
        do {
            let options = try await queryService.siteOptions(in: account.namespace)
            guard scope == InventoryAccountScope(account: account) else { return }
            siteOptions = options.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        } catch {
            guard scope == InventoryAccountScope(account: account) else { return }
            siteOptions = []
        }
    }

    func search() async {
        let scope = InventoryAccountScope(account: account)
        searchGeneration &+= 1
        let generation = searchGeneration
        state = .loading
        do {
            var bounded = query
            bounded.maximumResults = min(max(query.maximumResults, 1), 50)
            let found = try await queryService.search(bounded, in: account.namespace)
            try Task.checkCancellation()
            guard isCurrentSearch(generation, scope: scope) else { return }
            results = found.prefix(bounded.maximumResults).map { $0 }
            state = results.isEmpty ? .empty : .ready
        } catch is CancellationError {
            guard isCurrentSearch(generation, scope: scope) else { return }
            state = .empty
        } catch {
            guard isCurrentSearch(generation, scope: scope) else { return }
            state = .offline("Search uses the local mirror only. \(error.localizedDescription)")
        }
    }

    func select(_ id: ObjectID) async {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        let scope = InventoryAccountScope(account: account)
        selectedDetails = nil
        state = .loading
        do {
            guard let details = try await queryService.details(for: id, in: account.namespace) else {
                guard isCurrentSelection(generation, scope: scope) else { return }
                selectedDetails = nil
                state = .unavailable("This object is missing, tombstoned, outside this workspace, or unavailable to this account.")
                return
            }
            guard isCurrentSelection(generation, scope: scope) else { return }
            applySelection(details)
            await historyStore.recordRecent(id, in: scope)
            guard isCurrentSelection(generation, scope: scope) else { return }
            historyGeneration &+= 1
            let currentHistoryGeneration = historyGeneration
            let latestRecents = await historyStore.recent(in: scope)
            guard isCurrentSelection(generation, scope: scope), isCurrentHistory(currentHistoryGeneration, scope: scope) else { return }
            recents = latestRecents
            await refreshHistoryResults(in: scope, generation: currentHistoryGeneration)
        } catch {
            guard isCurrentSelection(generation, scope: scope) else { return }
            state = .offline("The object could not be loaded from this account's local mirror.")
        }
    }

    func resolveDeepLink(_ url: URL) async {
        guard let id = ObjectLink.objectID(from: url) else {
            state = .quarantined("Only canonical Nettwork object links can be opened.")
            return
        }
        await select(id)
    }

    func toggleFavorite(_ id: ObjectID) async {
        let scope = InventoryAccountScope(account: account)
        historyGeneration &+= 1
        let generation = historyGeneration
        let updatedFavorites = await historyStore.toggleFavorite(id, in: scope)
        guard isCurrentHistory(generation, scope: scope) else { return }
        favorites = updatedFavorites
        await refreshHistoryResults(in: scope, generation: generation)
    }

    func replaceAccount(_ account: AccountContext) {
        searchGeneration &+= 1
        selectionGeneration &+= 1
        historyGeneration &+= 1
        self.account = account
        results = []
        selectedDetails = nil
        favorites = []
        recents = []
        favoriteResults = []
        recentResults = []
        siteOptions = []
        state = .loading
    }

    private func isCurrentSearch(_ generation: UInt64, scope: InventoryAccountScope) -> Bool {
        generation == searchGeneration && scope == InventoryAccountScope(account: account)
    }

    private func isCurrentSelection(_ generation: UInt64, scope: InventoryAccountScope) -> Bool {
        generation == selectionGeneration && scope == InventoryAccountScope(account: account)
    }

    private func isCurrentHistory(_ generation: UInt64, scope: InventoryAccountScope) -> Bool {
        generation == historyGeneration && scope == InventoryAccountScope(account: account)
    }

    private func applySelection(_ details: InventoryObjectDetails) {
        selectedDetails = details
        if details.result.isConflicted {
            state = .conflict("This object has a reconciliation conflict.")
        } else if details.result.isPending {
            state = .pending("This object includes pending work-order changes.")
        } else {
            state = .ready
        }
    }

    private func refreshHistoryResults(in scope: InventoryAccountScope, generation: UInt64) async {
        guard isCurrentHistory(generation, scope: scope) else { return }
        let favoriteIDs = favorites.sorted()
        let recentIDs = uniqueIDs(recents)
        let requestedIDs = uniqueIDs(favoriteIDs + recentIDs)
        let resolved = (try? await queryService.results(for: requestedIDs, in: account.namespace)) ?? []
        guard isCurrentHistory(generation, scope: scope) else { return }
        let rowsByID = Dictionary(resolved.filter { !$0.isTombstoned }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        favoriteResults = favoriteIDs.compactMap { rowsByID[$0] }
        recentResults = recentIDs.compactMap { rowsByID[$0] }
    }

    private func uniqueIDs(_ ids: [ObjectID]) -> [ObjectID] {
        var seen = Set<ObjectID>()
        return ids.filter { seen.insert($0).inserted }
    }
}
