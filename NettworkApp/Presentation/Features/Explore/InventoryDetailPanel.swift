import FeatureContracts
import SwiftUI

struct InventoryDetailPanel: View {
    let model: InventoryExploreModel

    var body: some View {
        Group {
            if let details = model.selectedDetails {
                InventoryObjectSummary(details: details)
                    .navigationTitle(details.result.title)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                Task { await model.toggleFavorite(details.result.id) }
                            } label: {
                                Label(
                                    model.favorites.contains(details.result.id) ? "Remove favorite" : "Add favorite",
                                    systemImage: model.favorites.contains(details.result.id) ? "star.fill" : "star")
                            }
                            .accessibilityIdentifier("inventory.favorite-toggle")
                        }
                    }
            } else if model.state == .loading {
                NettworkLoadingState("Loading object…")
            } else {
                WorkbenchSelectionGuidance(state: model.state, title: "Select an object")
            }
        }
        .accessibilityIdentifier("inventory.detail")
    }
}

struct InventoryObjectSummary: View {
    let details: InventoryObjectDetails
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            summaryContent(width: geometry.size.width)
        }
    }

    private func summaryContent(width: CGFloat) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NettworkSpacing.large) {
                identity
                notices
                LazyVGrid(columns: columns(for: width), alignment: .leading, spacing: NettworkSpacing.medium) {
                    summarySection("Location", symbol: "building.2", values: details.containment)
                    summarySection("Connectivity", symbol: "cable.connector", values: [details.connectivitySummary])
                    summarySection("Address space", symbol: "network", values: details.logicalContext)
                    summarySection("Trace summary", symbol: "arrow.triangle.branch", values: [details.traceSummary])
                }
                NettworkDetailSection(title: "Recent activity", systemImage: "clock.arrow.circlepath") {
                    if details.recentAuditSummary.isEmpty {
                        Text("No recent activity recorded for this object.").foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: NettworkSpacing.standard) {
                            ForEach(details.recentAuditSummary, id: \.self) { entry in
                                Text(entry).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Label(
                    details.attachmentCount == 1 ? "1 attachment" : "\(details.attachmentCount) attachments",
                    systemImage: "paperclip"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(NettworkSpacing.large)
            .frame(maxWidth: .infinity)
        }
        .textSelection(.enabled)
    }

    private func columns(for width: CGFloat) -> [GridItem] {
        let count = width < 680 || dynamicTypeSize.isAccessibilitySize ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: NettworkSpacing.medium, alignment: .topLeading), count: count)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: NettworkSpacing.medium) {
            NettworkPageHeader(details.result.title, subtitle: details.result.subtitle, systemImage: details.result.kind.symbolName)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NettworkSpacing.medium) { identityMetadata }
                VStack(alignment: .leading, spacing: NettworkSpacing.small) { identityMetadata }
            }
        }
    }

    @ViewBuilder
    private var identityMetadata: some View {
        WorkbenchAuthorityBadge(result: details.result)
        Text(details.result.kind.title).font(.subheadline).foregroundStyle(.secondary)
        if let site = details.result.siteName {
            Label(site, systemImage: "mappin").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let pending = details.pendingSummary {
            NettworkNotice("Pending change", message: pending, style: .warning)
        }
        if let reservation = details.reservationSummary {
            NettworkNotice("Reserved for work", message: reservation)
        }
    }

    private func summarySection(_ title: String, symbol: String, values: [String]) -> some View {
        NettworkDetailSection(title: title, systemImage: symbol) {
            if values.isEmpty {
                Text("Not recorded").foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: NettworkSpacing.small) {
                    ForEach(values, id: \.self) { value in
                        Text(value).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
