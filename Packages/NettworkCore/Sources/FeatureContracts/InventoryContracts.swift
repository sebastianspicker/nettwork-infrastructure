import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum InventoryObjectKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case site, room, rack, device, port, cable, address, interface
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var symbolName: String {
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

public struct InventorySearchQuery: Equatable, Sendable {
    public var text: String
    public var kinds: Set<InventoryObjectKind>
    public var siteID: ObjectID?
    public var maximumResults: Int

    public init(text: String = "", kinds: Set<InventoryObjectKind> = Set<InventoryObjectKind>(), siteID: ObjectID? = nil, maximumResults: Int = 50) {
        self.text = text
        self.kinds = kinds
        self.siteID = siteID
        self.maximumResults = maximumResults
    }
}

public struct InventorySiteOption: Identifiable, Equatable, Sendable {
    public let id: ObjectID
    public let title: String

    public init(id: ObjectID, title: String) {
        self.id = id
        self.title = title
    }
}

public struct InventorySearchResult: Identifiable, Equatable, Sendable {
    public let id: ObjectID
    public let kind: InventoryObjectKind
    public let title: String
    public let subtitle: String
    public let siteName: String?
    public let searchTerms: [String]
    public let isTombstoned: Bool
    public let isPending: Bool
    public let isConflicted: Bool

    public init(
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

public struct InventoryObjectDetails: Equatable, Sendable {
    public let result: InventorySearchResult
    public let containment: [String]
    public let connectivitySummary: String
    public let traceSummary: String
    public let logicalContext: [String]
    public let reservationSummary: String?
    public let pendingSummary: String?
    public let recentAuditSummary: [String]
    public let attachmentCount: Int

    public init(
        result: InventorySearchResult,
        containment: [String],
        connectivitySummary: String,
        traceSummary: String,
        logicalContext: [String],
        reservationSummary: String?,
        pendingSummary: String?,
        recentAuditSummary: [String],
        attachmentCount: Int
    ) {
        self.result = result
        self.containment = containment
        self.connectivitySummary = connectivitySummary
        self.traceSummary = traceSummary
        self.logicalContext = logicalContext
        self.reservationSummary = reservationSummary
        self.pendingSummary = pendingSummary
        self.recentAuditSummary = recentAuditSummary
        self.attachmentCount = attachmentCount
    }
}

public struct InventoryAccountScope: Hashable, Sendable {
    public let accountRecordName: String
    public let workspaceID: ObjectID
    public let sessionGeneration: UInt64

    public init(account: AccountContext) {
        accountRecordName = account.namespace.cloudKitAccountRecordName
        workspaceID = account.namespace.workspaceID
        sessionGeneration = account.namespace.sessionGeneration
    }
}

public protocol InventoryQuerying: Sendable {
    func siteOptions(in namespace: PersistenceNamespace) async throws -> [InventorySiteOption]
    func search(_ query: InventorySearchQuery, in namespace: PersistenceNamespace) async throws -> [InventorySearchResult]
    func results(for ids: [ObjectID], in namespace: PersistenceNamespace) async throws -> [InventorySearchResult]
    func details(for id: ObjectID, in namespace: PersistenceNamespace) async throws -> InventoryObjectDetails?
}

public protocol InventoryHistoryStoring: Sendable {
    func recent(in scope: InventoryAccountScope) async -> [ObjectID]
    func favorites(in scope: InventoryAccountScope) async -> Set<ObjectID>
    func recordRecent(_ id: ObjectID, in scope: InventoryAccountScope) async
    func toggleFavorite(_ id: ObjectID, in scope: InventoryAccountScope) async -> Set<ObjectID>
}
