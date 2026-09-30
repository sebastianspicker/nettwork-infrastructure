import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct TemplateCatalogDetailScreen: View {
    let item: TemplateCatalogItem
    @Bindable var model: TemplateCatalogModel
    let onClone: (DeviceType) -> Void
    let onNewVersion: (DeviceType) -> Void
    let onMigration: (DeviceType, [DeviceTemplateMigrationPlan]) -> Void
    let onInstantiate: (DeviceType) -> Void

    var body: some View {
        List {
            Section {
                NettworkPageHeader(
                    item.name,
                    subtitle: "Review the definition and impact before staging a change request.",
                    systemImage: "square.stack.3d.up"
                )
            }
            .listRowInsets(EdgeInsets())
            TemplateCatalogSummarySection(item: item)
            TemplateCatalogDefinitionContent(
                model: model,
                item: item,
                onClone: onClone,
                onNewVersion: onNewVersion,
                onMigration: onMigration,
                onInstantiate: onInstantiate
            )
            TemplateMigrationImpactSection(impacts: model.impacts)
        }
        .navigationTitle(item.name)
        .task(id: item.id) {
            await model.loadDetails(for: item.id)
        }
    }
}

private struct TemplateCatalogSummarySection: View {
    let item: TemplateCatalogItem

    var body: some View {
        Section("Summary") {
            LabeledContent("Version", value: "\(item.version)")
            LabeledContent("Ports", value: "\(item.portCount)")
            LabeledContent("Module slots", value: "\(item.moduleCount)")
            Text(item.validationSummary)
        }
    }
}

private struct TemplateCatalogDefinitionContent: View {
    @Bindable var model: TemplateCatalogModel
    let item: TemplateCatalogItem
    let onClone: (DeviceType) -> Void
    let onNewVersion: (DeviceType) -> Void
    let onMigration: (DeviceType, [DeviceTemplateMigrationPlan]) -> Void
    let onInstantiate: (DeviceType) -> Void

    var body: some View {
        if let template = model.selectedTemplate, template.id == item.id {
            TemplateCatalogLoadedDefinition(
                template: template, model: model, onClone: onClone,
                onNewVersion: onNewVersion, onMigration: onMigration, onInstantiate: onInstantiate
            )
        } else if let detailMessage = model.detailMessage {
            Section("Definition unavailable") {
                Label(detailMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityStatus(detailMessage, identifier: "templates.detail-error")
            }
        } else {
            Section {
                HStack {
                    ProgressView()
                    Text("Loading template definition…")
                }
            }
        }
    }
}

private struct TemplateCatalogLoadedDefinition: View {
    let template: DeviceType
    @Bindable var model: TemplateCatalogModel
    let onClone: (DeviceType) -> Void
    let onNewVersion: (DeviceType) -> Void
    let onMigration: (DeviceType, [DeviceTemplateMigrationPlan]) -> Void
    let onInstantiate: (DeviceType) -> Void

    var body: some View {
        TemplateDefinitionSummary(template: template)
        TemplateChangeRequestsSection(template: template, model: model, onClone: onClone, onNewVersion: onNewVersion, onInstantiate: onInstantiate)
        TemplateMigrationDecisionSection(template: template, model: model, onMigration: onMigration)
    }
}

private struct TemplateChangeRequestsSection: View {
    let template: DeviceType
    @Bindable var model: TemplateCatalogModel
    let onClone: (DeviceType) -> Void
    let onNewVersion: (DeviceType) -> Void
    let onInstantiate: (DeviceType) -> Void

    var body: some View {
        Section("Change requests") {
            Text("Each option opens a request that is staged for review. The template definition remains unchanged until that workflow completes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Clone template") { onClone(template) }.disabled(!model.canRequestChanges)
            Button("Create new version") { onNewVersion(template) }.disabled(!model.canRequestChanges)
            Button("Instantiate device") { onInstantiate(template) }.disabled(!model.canRequestChanges)
        }
    }
}

private struct TemplateMigrationDecisionSection: View {
    let template: DeviceType
    @Bindable var model: TemplateCatalogModel
    let onMigration: (DeviceType, [DeviceTemplateMigrationPlan]) -> Void

    var body: some View {
        Section("Migration decisions") {
            Text("Review the proposed impacts before deciding which device migrations to stage.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.migrationPlans.isEmpty {
                Text("No per-device migration plans are available for staging.").foregroundStyle(.secondary)
            } else {
                Button("Review and stage migration decisions") { onMigration(template, model.migrationPlans) }
                    .disabled(!model.canRequestChanges)
            }
        }
    }
}

private struct TemplateMigrationImpactSection: View {
    let impacts: [TemplateMigrationImpactSnapshot]

    var body: some View {
        Section("Migration impact") {
            if impacts.isEmpty {
                Text("No impacted ports were reported.").foregroundStyle(.secondary)
            } else {
                ForEach(impacts) { impact in
                    Label(impact.explanation, systemImage: impact.requiresCableReview ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(impact.requiresCableReview ? .orange : .primary)
                        .accessibilityLabel("\(impact.action.rawValue): \(impact.explanation)\(impact.requiresCableReview ? ". Cable review required." : "")")
                }
            }
        }
    }
}

struct TemplateDefinitionSummary: View {
    let template: DeviceType

    var body: some View {
        Section("Definition") {
            LabeledContent("Kind", value: template.kind.rawValue)
            LabeledContent("Rack height", value: "\(template.rackHeightRU) RU")
            LabeledContent("Custom fields", value: "\(template.customFieldSchemas.count) schema, \(template.customFields.count) values")
            if !template.portTemplates.isEmpty {
                NavigationLink("Review \(template.portTemplates.count) port definitions") {
                    List(template.portTemplates) { port in
                        LabeledContent(port.name, value: "\(port.medium.rawValue) · \(port.connector.rawValue) · \(port.face.rawValue) \(port.order)")
                    }
                    .navigationTitle("Ports")
                }
            }
            TemplateCSVPreview(template: template)
        }
    }
}

struct ModuleTemplateDetailScreen: View {
    let template: ModuleTemplate
    @Bindable var model: TemplateCatalogModel
    let onClone: () -> Void
    let onNewVersion: () -> Void

    var body: some View {
        List {
            Section {
                NettworkPageHeader(
                    template.name,
                    subtitle: "Review this module definition and stage a request for any change.",
                    systemImage: "puzzlepiece.extension"
                )
            }
            .listRowInsets(EdgeInsets())
            Section("Definition") {
                LabeledContent("Version", value: "\(template.version)")
                LabeledContent("Ports", value: "\(template.ports.count)")
                LabeledContent("Custom fields", value: "\(template.customFieldSchemas.count) schema")
                TemplateCSVPreview(moduleTemplate: template)
            }
            Section("Change requests") {
                Text("Changes are staged for review and do not update the module directly from this screen.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Clone module template", action: onClone).disabled(!model.canRequestChanges)
                Button("Create new version", action: onNewVersion).disabled(!model.canRequestChanges)
            }
        }
        .navigationTitle(template.name)
    }
}

struct TemplateCSVPreview: View {
    let rows: [String]

    init(template: DeviceType) {
        let schema = Self.schema(for: .deviceTypes)
        rows = Self.render(
            schema: schema,
            values: [
                template.id.description, template.name, template.kind.rawValue,
                Self.json(template.customFields), "\(template.version)", "\(template.rackHeightRU)",
                Self.json(template.portTemplates), Self.json(template.moduleSlots), Self.json(template.customFieldSchemas),
            ])
    }

    init(moduleTemplate: ModuleTemplate) {
        let schema = Self.schema(for: .moduleTemplates)
        rows = Self.render(
            schema: schema,
            values: [
                moduleTemplate.id.description, moduleTemplate.name, Self.json(moduleTemplate.ports),
                "\(moduleTemplate.version)", Self.json(moduleTemplate.customFieldSchemas),
            ])
    }

    private static func schema(for kind: CSVTable) -> CSVTemplate {
        guard let schema = CSVSchemaV2.templates[kind] else {
            preconditionFailure("Every template kind must have a CSV schema.")
        }
        return schema
    }

    var body: some View {
        NavigationLink("Preview CSV row") {
            List(rows, id: \.self) { Text($0).font(.footnote.monospaced()).textSelection(.enabled) }
                .navigationTitle("CSV preview")
        }
        .accessibilityHint("Shows the bounded RFC 4180 preview for this template.")
    }

    private static func render(schema: CSVTemplate, values: [String]) -> [String] {
        let data = CSVExport.encode(rows: [schema.columns, values])
        return String(decoding: data.prefix(16 * 1024), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(2)
            .map { String($0) }
    }

    private static func json<T: Encodable>(_ value: T) -> String {
        String(data: (try? JSONEncoder().encode(value)) ?? Data(), encoding: .utf8) ?? "[]"
    }
}
