import Foundation
import NetworkModel
import Observation
import WorkspaceChangeControl

enum AppBootstrapOutcome: Equatable {
    case ready(SyncReceipt)
    case attention(SyncReceipt)
    case offline(String)
}

@MainActor
protocol AppBootstrapServing: AnyObject {
    func start() async -> AppBootstrapOutcome
    func synchronizeForeground() async -> AppBootstrapOutcome
    func stop() async
}

/// Production bootstrap is injected with the account/workspace activation and
/// teardown operations owned by application composition. The sync coordinator
/// cannot run until activation succeeds, and teardown always revokes the
/// current account-scoped lease before the app drops its feature graph.
@MainActor
final class ProductionAppBootstrapService: AppBootstrapServing {
    private let activateWorkspace: () async throws -> Void
    private let syncCoordinator: any SyncCoordinator
    private let invalidateWorkspace: () async -> Void
    private var activated = false

    init(
        activateWorkspace: @escaping () async throws -> Void,
        syncCoordinator: any SyncCoordinator,
        invalidateWorkspace: @escaping () async -> Void
    ) {
        self.activateWorkspace = activateWorkspace
        self.syncCoordinator = syncCoordinator
        self.invalidateWorkspace = invalidateWorkspace
    }

    func start() async -> AppBootstrapOutcome {
        do {
            try await activateWorkspace()
            activated = true
            return await synchronizeForeground()
        } catch {
            activated = false
            return .offline(error.localizedDescription)
        }
    }

    func synchronizeForeground() async -> AppBootstrapOutcome {
        guard activated else {
            return .offline("No verified account-scoped workspace is active.")
        }
        return Self.outcome(for: await syncCoordinator.synchronizeForeground())
    }

    func stop() async {
        guard activated else { return }
        activated = false
        await invalidateWorkspace()
    }

    private static func outcome(for receipt: SyncReceipt) -> AppBootstrapOutcome {
        guard !receipt.failures.isEmpty else { return .ready(receipt) }
        if receipt.failures.contains(where: { $0.category == .accountUnavailable }) {
            return .offline(receipt.failures.map(\.message).joined(separator: " "))
        }
        return .attention(receipt)
    }
}

@MainActor
final class UnconfiguredAppBootstrapService: AppBootstrapServing {
    private let message: String

    init(message: String = "CloudKit workspace setup has not been configured.") {
        self.message = message
    }

    func start() async -> AppBootstrapOutcome {
        .offline(message)
    }

    func synchronizeForeground() async -> AppBootstrapOutcome {
        .offline(message)
    }

    func stop() async {}
}

@MainActor
struct AppRuntimeComposition {
    let dependencies: AppDependencies
    let router: AppRouter

    static var unconfigured: AppRuntimeComposition {
        AppRuntimeComposition(dependencies: AppDependencies(), router: AppRouter())
    }

    static func production(
        features: AppFeatureComposition,
        activateWorkspace: @escaping () async throws -> Void,
        syncCoordinator: any SyncCoordinator,
        invalidateWorkspace: @escaping () async -> Void
    ) -> AppRuntimeComposition {
        let bootstrap = ProductionAppBootstrapService(
            activateWorkspace: activateWorkspace,
            syncCoordinator: syncCoordinator,
            invalidateWorkspace: invalidateWorkspace
        )
        return AppRuntimeComposition(
            dependencies: AppDependencies(
                features: .configured(features),
                bootstrapService: bootstrap
            ),
            router: AppRouter()
        )
    }

    /// Production callers supply the fully authorized graph input rather than
    /// constructing presentation models separately from their authority
    /// bundle. The default app entry point remains unconfigured until the
    /// organization provides its CloudKit account, container, and role seams.
    static func production(
        featureInput: ProductionFeatureGraphInput,
        activateWorkspace: @escaping () async throws -> Void,
        syncCoordinator: any SyncCoordinator,
        invalidateWorkspace: @escaping () async -> Void
    ) -> AppRuntimeComposition {
        production(
            features: ProductionFeatureGraphFactory.make(featureInput),
            activateWorkspace: activateWorkspace,
            syncCoordinator: syncCoordinator,
            invalidateWorkspace: invalidateWorkspace
        )
    }
}

@MainActor
@Observable
final class AppDependencies {
    enum SyncStatus: Equatable {
        case loading
        case syncing
        case ready
        case attention(reason: String)
        case offline(reason: String)

        var title: String {
            switch self {
            case .loading:
                "Preparing workspace"
            case .syncing:
                "Synchronizing changes"
            case .ready:
                "Up to date"
            case .attention:
                "Sync needs attention"
            case .offline:
                "Offline workspace"
            }
        }

        var detail: String {
            switch self {
            case .loading:
                "Loading the local workspace mirror."
            case .syncing:
                "Pending changes are being checked with the workspace."
            case .ready:
                "The local workspace mirror is current."
            case .attention(let reason):
                reason
            case .offline(let reason):
                reason
            }
        }
    }

    private(set) var syncStatus: SyncStatus
    private(set) var lastSyncReceipt: SyncReceipt?
    let features: AppFeatureRegistry
    private let bootstrapService: any AppBootstrapServing
    private var hasBootstrapped = false

    init(
        syncStatus: SyncStatus = .loading,
        features: AppFeatureRegistry,
        bootstrapService: any AppBootstrapServing
    ) {
        self.syncStatus = syncStatus
        self.features = features
        self.bootstrapService = bootstrapService
    }

    convenience init(
        syncStatus: SyncStatus = .loading,
        bootstrapService: any AppBootstrapServing
    ) {
        self.init(syncStatus: syncStatus, features: .unconfigured, bootstrapService: bootstrapService)
    }

    convenience init(syncStatus: SyncStatus = .loading) {
        self.init(
            syncStatus: syncStatus,
            features: .unconfigured,
            bootstrapService: UnconfiguredAppBootstrapService()
        )
    }

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        syncStatus = .loading
        apply(await bootstrapService.start())
    }

    func synchronizeForeground() async {
        syncStatus = .syncing
        apply(await bootstrapService.synchronizeForeground())
    }

    func shutdown() async {
        await bootstrapService.stop()
        hasBootstrapped = false
        lastSyncReceipt = nil
        syncStatus = .offline(reason: "The account-scoped workspace is closed.")
    }

    private func apply(_ outcome: AppBootstrapOutcome) {
        switch outcome {
        case .ready(let receipt):
            lastSyncReceipt = receipt
            syncStatus = .ready
        case .attention(let receipt):
            lastSyncReceipt = receipt
            syncStatus = .attention(reason: receipt.failures.map(\.message).joined(separator: " "))
        case .offline(let reason):
            lastSyncReceipt = nil
            syncStatus = .offline(reason: reason)
        }
    }
}

enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case explore
    case floorPlans
    case racks
    case trace
    case scan
    case workOrders
    case ipam
    case reports
    case importExport
    case templates
    case audit
    case administration
    case reconciliation
    case labels

    private struct Presentation {
        let title: String
        let symbolName: String
        let emptyMessage: String
    }

    private static let presentations: [AppSection: Presentation] = [
        .explore: .init(
            title: "Explore", symbolName: "point.3.connected.trianglepath.dotted",
            emptyMessage: "Search an asset code, hostname, address, rack, or port to begin mapping connections."),
        .floorPlans: .init(title: "Floor Plans", symbolName: "map", emptyMessage: "Import a floor plan and add normalized device or outlet anchors."),
        .racks: .init(title: "Racks", symbolName: "server.rack", emptyMessage: "Add a rack to document its front and rear elevations."),
        .trace: .init(title: "Trace", symbolName: "arrow.triangle.branch", emptyMessage: "Select a port or scan a label to trace a physical connection."),
        .scan: .init(title: "Scan", symbolName: "qrcode.viewfinder", emptyMessage: "Scan an opaque Nettwork asset label or enter its identifier."),
        .workOrders: .init(
            title: "Work Orders", symbolName: "checklist", emptyMessage: "Create a work order before reserving or changing physical connections."),
        .ipam: .init(title: "IPAM", symbolName: "network", emptyMessage: "Add a VRF, prefix, or VLAN to start documenting address space."),
        .reports: .init(
            title: "Reports", symbolName: "chart.bar.doc.horizontal",
            emptyMessage: "Reports will appear as the local workspace collects inventory and audit data."),
        .importExport: .init(
            title: "Import/Export", symbolName: "arrow.left.arrow.right",
            emptyMessage: "Import is available only for an empty workspace; exports remain local until configured."),
        .templates: .init(title: "Templates", symbolName: "square.on.square", emptyMessage: "Create reusable device, module, and port templates."),
        .audit: .init(title: "Audit", symbolName: "clock.arrow.circlepath", emptyMessage: "Accepted and rejected privileged operations will appear here."),
        .administration: .init(
            title: "Administration", symbolName: "gearshape", emptyMessage: "Connect an organization workspace to manage access and sync policies."),
        .reconciliation: .init(
            title: "Reconciliation", symbolName: "arrow.triangle.2.circlepath.circle",
            emptyMessage: "Review base, intended, and current values before creating corrective work."),
        .labels: .init(title: "Labels", symbolName: "tag", emptyMessage: "Create privacy-safe labels with opaque object routes."),
    ]

    var id: String { rawValue }
    var title: String { presentation.title }
    var symbolName: String { presentation.symbolName }
    var emptyMessage: String { presentation.emptyMessage }

    private var presentation: Presentation {
        guard let presentation = Self.presentations[self] else {
            preconditionFailure("Every AppSection must define a presentation.")
        }
        return presentation
    }
}

enum AppRoute: Hashable {
    case section(AppSection)
    case object(UUID)

    init?(url: URL) {
        guard url.scheme?.lowercased() == "nettwork", url.host?.lowercased() == "object" else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count == 1, let identifier = UUID(uuidString: pathComponents[0]) else {
            return nil
        }
        self = .object(identifier)
    }
}

struct DeepLinkRequest: Equatable {
    let route: AppRoute
    private let token = UUID()
}

@MainActor
@Observable
final class AppRouter {
    var selectedSection: AppSection? = .explore
    var deepLinkRequest: DeepLinkRequest?

    func handle(url: URL) {
        guard let route = AppRoute(url: url) else { return }
        selectedSection = .explore
        deepLinkRequest = DeepLinkRequest(route: route)
    }
}
