enum CompactTab: String, CaseIterable, Identifiable, Hashable {
    case explore
    case workOrders
    case trace
    case ipam
    case more

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: "Explore"
        case .workOrders: "Work Orders"
        case .trace: "Trace"
        case .ipam: "IPAM"
        case .more: "More"
        }
    }

    var symbolName: String {
        switch self {
        case .explore: AppSection.explore.symbolName
        case .workOrders: AppSection.workOrders.symbolName
        case .trace: AppSection.trace.symbolName
        case .ipam: AppSection.ipam.symbolName
        case .more: "ellipsis.circle"
        }
    }

    var sections: [AppSection] {
        switch self {
        case .explore: [.explore]
        case .workOrders: [.workOrders]
        case .trace: [.trace]
        case .ipam: [.ipam]
        case .more: [.floorPlans, .racks, .scan, .reports, .importExport, .templates, .labels, .reconciliation, .audit, .administration]
        }
    }
}
