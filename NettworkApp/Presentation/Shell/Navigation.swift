import Foundation
import Observation

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
