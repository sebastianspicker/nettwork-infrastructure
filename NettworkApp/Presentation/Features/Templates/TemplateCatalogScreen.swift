import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct TemplateCatalogScreen: View {
    @Bindable var model: TemplateCatalogModel
    @State private var destination: TemplateSheetDestination?
    let statusAnnouncer: any AccessibilityStatusAnnouncing

    @MainActor init(
        model: TemplateCatalogModel,
        statusAnnouncer: any AccessibilityStatusAnnouncing = AccessibilityStatusAnnouncer()
    ) {
        self.model = model
        self.statusAnnouncer = statusAnnouncer
    }

    var body: some View {
        List {
            Section {
                NettworkPageHeader(
                    "Templates",
                    subtitle: "Review definitions and stage changes as work-order requests for policy and audit review.",
                    systemImage: "square.stack.3d.up"
                )
            }
            .listRowInsets(EdgeInsets())
            TemplateCatalogContents(model: model, destination: $destination)
        }
        .navigationTitle("Templates")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    destination = .editor(.create)
                } label: {
                    Label("New template", systemImage: "plus")
                }
                .disabled(!model.canRequestChanges)
                .accessibilityHint(model.canRequestChanges ? "Stages a new template work-order request." : model.permissionMessage)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("New module template") { destination = .moduleEditor(.create) }
                    .disabled(!model.canRequestChanges)
            }
        }
        .sheet(item: $destination) { destination in
            switch destination {
            case .editor(let route):
                TemplateEditorSheet(route: route, model: model)
            case .migration(let template, let plans):
                TemplateMigrationDecisionSheet(template: template, plans: plans, model: model)
            case .instantiate(let template):
                TemplateInstantiationSheet(template: template, moduleTemplates: model.moduleTemplates, model: model)
            case .moduleEditor(let route):
                ModuleTemplateEditorSheet(route: route, model: model)
            }
        }
        .task {
            await model.load()
        }
        .onChange(of: model.state) { _, state in
            statusAnnouncer.announce(templateCatalogStatus(state))
        }
        .onChange(of: model.detailMessage) { _, message in
            if let message { statusAnnouncer.announce(message) }
        }
    }

    private func templateCatalogStatus(_ state: InventoryPresentationState) -> String {
        switch state {
        case .loading: "Loading the template catalog."
        case .ready: "Template catalog is ready."
        case .empty: "No template definitions are available in this workspace."
        case .offline(let message), .pending(let message), .conflict(let message),
            .quarantined(let message), .permissionDenied(let message), .unavailable(let message):
            message
        }
    }
}

private struct TemplateCatalogContents: View {
    @Bindable var model: TemplateCatalogModel
    @Binding var destination: TemplateSheetDestination?

    var body: some View {
        TemplateAdministrationNotice(policy: model.policy)
        if let workOrderID = model.lastStagedWorkOrderID {
            TemplateStagedRequestSection(workOrderID: workOrderID)
        }
        TemplateCatalogStateMessage(state: model.state)
        TemplateCatalogItemsSection(model: model, destination: $destination)
        TemplateModuleItemsSection(model: model, destination: $destination)
    }
}

private struct TemplateStagedRequestSection: View {
    let workOrderID: ObjectID

    var body: some View {
        Section("Staged request") {
            LabeledContent("Work order", value: workOrderID.description)
                .textSelection(.enabled)
                .accessibilityLabel("Staged work order \(workOrderID.description)")
                .accessibilityStatus(
                    "Template work order \(workOrderID.description) is staged for policy and audit review.",
                    identifier: "templates.staged-work-order-status"
                )
        }
    }
}

private struct TemplateCatalogItemsSection: View {
    @Bindable var model: TemplateCatalogModel
    @Binding var destination: TemplateSheetDestination?

    var body: some View {
        Section("Catalog") {
            Text("Select a template to review its definition, migration impact, and available staged-change actions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(model.items) { item in
                NavigationLink {
                    TemplateCatalogDetailScreen(
                        item: item, model: model,
                        onClone: { destination = .editor(.clone($0)) },
                        onNewVersion: { destination = .editor(.newVersion($0)) },
                        onMigration: { destination = .migration(template: $0, plans: $1) },
                        onInstantiate: { destination = .instantiate($0) }
                    )
                } label: {
                    TemplateCatalogRow(item: item)
                }
                .accessibilityIdentifier("templates.item.\(item.id.description)")
            }
        }
    }
}

private struct TemplateModuleItemsSection: View {
    @Bindable var model: TemplateCatalogModel
    @Binding var destination: TemplateSheetDestination?

    var body: some View {
        Section("Module templates") {
            Text("Module templates define the options that device template slots can allow.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach(model.moduleTemplates) { template in
                NavigationLink(template.name) {
                    ModuleTemplateDetailScreen(
                        template: template, model: model,
                        onClone: { destination = .moduleEditor(.clone(template)) },
                        onNewVersion: { destination = .moduleEditor(.newVersion(template)) }
                    )
                }
                .accessibilityIdentifier("templates.module.\(template.id.description)")
            }
        }
    }
}

struct TemplateCatalogRow: View {
    let item: TemplateCatalogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.name)
            Text("Version \(item.version) · \(item.portCount) ports · \(item.moduleCount) slots")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(item.validationSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), version \(item.version), \(item.portCount) ports, \(item.moduleCount) module slots. \(item.validationSummary)")
    }
}

struct TemplateAdministrationNotice: View {
    let policy: TemplateAdministrationPolicy

    var body: some View {
        Section {
            switch policy {
            case .allowed:
                NettworkNotice(
                    "Reviewed changes",
                    message: "Changes create work-order requests for review. They never apply directly from this screen.",
                    style: .information
                )
            case .readOnly:
                NettworkNotice(
                    "Read-only access",
                    message: "You can review definitions and migration impact.",
                    style: .information
                )
            case .denied(let reason):
                NettworkNotice("Changes unavailable", message: reason, style: .critical)
                    .accessibilityStatus(reason, identifier: "templates.policy-error")
            }
        }
        .accessibilityElement(children: .combine)
    }
}

@ViewBuilder
@MainActor
private func TemplateCatalogStateMessage(state: InventoryPresentationState) -> some View {
    switch state {
    case .loading:
        NettworkLoadingState("Loading the template catalog")
    case .ready:
        EmptyView()
    case .empty:
        ContentUnavailableView(
            "No templates",
            systemImage: "square.stack.3d.up.slash",
            description: Text("No template definitions are available in this workspace.")
        )
        .accessibilityStatus("No template definitions are available in this workspace.", identifier: "templates.status.empty")
    case .offline(let message), .unavailable(let message):
        ContentUnavailableView("Templates unavailable", systemImage: "wifi.exclamationmark", description: Text(message))
            .accessibilityStatus(message, identifier: "templates.status.unavailable")
    case .pending(let message):
        Label(message, systemImage: "clock.badge.checkmark")
            .foregroundStyle(.secondary)
            .accessibilityStatus(message, identifier: "templates.status.pending")
    case .conflict(let message), .quarantined(let message), .permissionDenied(let message):
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .accessibilityStatus(message, identifier: "templates.status.error")
    }
}
