import FeatureContracts
import Foundation
import NetworkModel
import SwiftUI

struct TraceStartScreen: View {
    let model: TraceInspectionModel
    @Bindable var inventory: InventoryExploreModel

    var body: some View {
        List {
            TraceSelectedPortSection(port: selectedPort)
            TracePortSearchSection(inventory: inventory)
            TraceIdentifierSection()
        }
        .navigationTitle("Trace")
        .task {
            inventory.query.kinds = [.port]
            await inventory.loadSiteOptions()
            await inventory.search()
        }
        .navigationDestination(for: AppTraceRoute.self) { route in
            TraceInspectionScreen(model: model, startPortID: route.portID)
        }
    }

    private var selectedPort: InventorySearchResult? {
        guard let result = inventory.selectedDetails?.result, result.kind == .port else { return nil }
        return result
    }
}

struct AppTraceRoute: Hashable {
    let portID: ObjectID
}

private struct TraceSelectedPortSection: View {
    let port: InventorySearchResult?

    var body: some View {
        if let port {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: NettworkSpacing.xSmall) {
                        Text(port.title).font(.headline)
                        Text(port.subtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: port.kind.symbolName)
                        .foregroundStyle(Color.nettworkAccent)
                }

                NavigationLink(value: AppTraceRoute(portID: port.id)) {
                    Label("Inspect trace", systemImage: "arrow.triangle.branch")
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("trace.inspect")
            } header: {
                Text("Start from the selected port")
            } footer: {
                Text("Inspect the mirrored physical and logical path from this port.")
            }
        } else {
            NettworkNotice(
                "Choose a starting port",
                message: "Search the scoped local inventory or scan a privacy-safe label before starting a trace."
            )
            .listRowInsets(EdgeInsets())
        }
    }
}

private struct TracePortSearchSection: View {
    @Bindable var inventory: InventoryExploreModel

    var body: some View {
        Section {
            sitePicker
            searchField
            Button(action: searchPorts) {
                Label("Search ports", systemImage: "magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("trace.search-ports")
            portResults
        } header: {
            Text("Find a starting port")
        } footer: {
            Text("Search stays within the active account-scoped local mirror.")
        }
    }

    private var sitePicker: some View {
        Picker("Site", selection: $inventory.query.siteID) {
            Text("All sites").tag(Optional<ObjectID>.none)
            ForEach(inventory.siteOptions) { site in
                Text(site.title).tag(Optional(site.id))
            }
        }
    }

    private var searchField: some View {
        TextField("Port label, device, rack, or address", text: $inventory.query.text)
            #if os(iOS)
                .textInputAutocapitalization(.never)
            #endif
            .autocorrectionDisabled()
            .onSubmit(searchPorts)
            .accessibilityIdentifier("trace.port-search")
    }

    @ViewBuilder
    private var portResults: some View {
        if case .loading = inventory.state {
            NettworkLoadingState("Searching ports")
        } else if results.isEmpty {
            NettworkEmptyState(
                "No matching ports",
                systemImage: "magnifyingglass",
                message: "Adjust the site or search terms in the active account-scoped local mirror."
            )
        } else {
            ForEach(results) { result in
                TracePortResultRow(result: result) {
                    await inventory.select(result.id)
                }
            }
        }
    }

    private var results: [InventorySearchResult] {
        inventory.results.filter { $0.kind == .port && !$0.isTombstoned }
    }

    private func searchPorts() {
        inventory.query.kinds = [.port]
        Task { await inventory.search() }
    }
}

private struct TracePortResultRow: View {
    let result: InventorySearchResult
    let select: () async -> Void

    var body: some View {
        Button {
            Task { await select() }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: NettworkSpacing.xSmall) {
                    Text(result.title)
                    Text(result.subtitle).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: result.kind.symbolName)
            }
        }
        .accessibilityLabel("Port, \(result.title), \(result.subtitle)")
        .accessibilityValue(result.isConflicted ? "Conflict" : result.isPending ? "Pending work" : "Available")
    }
}

private struct TraceIdentifierSection: View {
    @State private var portIdentifier = ""

    var body: some View {
        Section {
            DisclosureGroup {
                TextField("Port UUID", text: $portIdentifier)
                    #if os(iOS)
                        .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                    .font(NettworkTypography.identifier)
                    .accessibilityIdentifier("trace.start-port")
                if let uuid = UUID(uuidString: portIdentifier) {
                    NavigationLink("Inspect trace", value: AppTraceRoute(portID: ObjectID(uuid)))
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("trace.inspect-identifier")
                }
            } label: {
                Label("Use an opaque identifier", systemImage: "number")
            }
        } footer: {
            Text("Direct identifiers are intended for support and privacy-safe handoff workflows.")
        }
    }
}
