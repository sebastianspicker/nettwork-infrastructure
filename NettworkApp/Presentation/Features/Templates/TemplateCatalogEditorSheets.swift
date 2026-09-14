import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct TemplateEditorSheet: View {
    @Environment(\.dismiss) private var dismiss

    let route: TemplateEditorRoute
    @Bindable var model: TemplateCatalogModel
    @State private var draft: DeviceType
    @State private var title = ""
    @State private var ticketID = ""
    @State private var notes = ""
    @State private var validationMessage: String?
    @State private var isStaging = false

    init(route: TemplateEditorRoute, model: TemplateCatalogModel) {
        self.route = route
        self.model = model
        _draft = State(initialValue: route.initialTemplate())
        _title = State(initialValue: route.title)
    }

    var body: some View {
        NavigationStack {
            TemplateEditorForm(
                draft: $draft,
                title: $title,
                ticketID: $ticketID,
                notes: $notes,
                moduleTemplates: model.moduleTemplates,
                validationMessage: validationMessage
            )
            .navigationTitle(route.title)
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStaging ? "Staging…" : "Stage request") {
                        stageRequest()
                    }
                    .disabled(
                        isStaging
                            || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || ticketID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
        }
    }

    private func stageRequest() {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "Template name is required."
            return
        }
        do {
            try TemplateCatalog.validate(deviceTemplate: draft)
            draft.customFields = try CustomFieldValidator.resolvedValues(values: draft.customFields, against: draft.customFieldSchemas)
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
            return
        }

        isStaging = true
        let request = TemplateChangeRequest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            ticketID: ticketID.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            targetTemplate: draft,
            requestKind: route.requestKind
        )
        Task {
            let stagedID = await model.stage(request)
            isStaging = false
            if stagedID != nil { dismiss() }
        }
    }
}

private struct TemplateEditorForm: View {
    @Binding var draft: DeviceType
    @Binding var title: String
    @Binding var ticketID: String
    @Binding var notes: String
    let moduleTemplates: [ModuleTemplate]
    let validationMessage: String?

    var body: some View {
        Form {
            TemplateRequestSection(title: $title, ticketID: $ticketID, notes: $notes)
            TemplateDetailsSection(draft: $draft)
            TemplatePortsSection(draft: $draft)
            TemplateModuleSlotsSection(draft: $draft, moduleTemplates: moduleTemplates)
            TemplateCustomFieldsSection(draft: $draft)
            TemplateEditorValidationSection(message: validationMessage)
        }
    }
}

private struct TemplateRequestSection: View {
    @Binding var title: String
    @Binding var ticketID: String
    @Binding var notes: String

    var body: some View {
        Section("Request") {
            TextField("Request title", text: $title)
                #if os(iOS)
                    .textInputAutocapitalization(.sentences)
                #endif
            TextField("Change ticket", text: $ticketID)
                #if os(iOS)
                    .textInputAutocapitalization(.characters)
                #endif
                .autocorrectionDisabled()
            TextField("Review notes", text: $notes, axis: .vertical).lineLimit(3...6)
        }
    }
}

private struct TemplateDetailsSection: View {
    @Binding var draft: DeviceType

    var body: some View {
        Section("Template") {
            TextField("Name", text: $draft.name)
            Picker("Kind", selection: $draft.kind) {
                ForEach(DeviceKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Stepper("Rack height: \(draft.rackHeightRU) RU", value: $draft.rackHeightRU, in: 1...100)
            LabeledContent("Version", value: "\(draft.version)")
        }
    }
}

private struct TemplatePortsSection: View {
    @Binding var draft: DeviceType

    var body: some View {
        Section("Ports") {
            ForEach($draft.portTemplates) { $port in
                NavigationLink(port.name.isEmpty ? "Unnamed port" : port.name) { TemplatePortEditor(port: $port) }
            }
            .onDelete { draft.portTemplates.remove(atOffsets: $0) }
            Button("Add port", action: addPort)
        }
    }

    private func addPort() {
        let order = (draft.portTemplates.map(\.order).max() ?? -1) + 1
        draft.portTemplates.append(PortTemplate(name: "Port \(order + 1)", medium: .copper, connector: .rj45, order: order))
    }
}

private struct TemplateModuleSlotsSection: View {
    @Binding var draft: DeviceType
    let moduleTemplates: [ModuleTemplate]

    var body: some View {
        Section("Module slots") {
            ForEach($draft.moduleSlots) { $slot in
                NavigationLink(slot.displayName.isEmpty ? "Unnamed module slot" : slot.displayName) {
                    TemplateModuleSlotEditor(slot: $slot, moduleTemplates: moduleTemplates)
                }
            }
            .onDelete { draft.moduleSlots.remove(atOffsets: $0) }
            Button("Add module slot", action: addSlot)
        }
    }

    private func addSlot() {
        let index = draft.moduleSlots.count + 1
        draft.moduleSlots.append(
            ModuleSlotTemplate(
                key: "slot_\(index)",
                displayName: "Slot \(index)",
                allowedModuleTemplateIDs: moduleTemplates.prefix(1).map(\.id)
            )
        )
    }
}

private struct TemplateCustomFieldsSection: View {
    @Binding var draft: DeviceType

    var body: some View {
        Section("Custom field schemas") {
            ForEach($draft.customFieldSchemas) { $schema in
                NavigationLink(schema.displayName.isEmpty ? schema.key : schema.displayName) {
                    TemplateCustomFieldSchemaEditor(schema: $schema, values: $draft.customFields)
                }
            }
            .onDelete { draft.customFieldSchemas.remove(atOffsets: $0) }
            Button("Add custom field schema", action: addSchema)
        }
        Section("Custom field values") {
            if draft.customFieldSchemas.isEmpty { Text("Add a schema before entering a value.").foregroundStyle(.secondary) }
            ForEach(draft.customFieldSchemas) { schema in
                NavigationLink(schema.displayName.isEmpty ? schema.key : schema.displayName) {
                    TemplateCustomFieldValueEditor(schema: schema, values: $draft.customFields)
                }
            }
        }
    }

    private func addSchema() {
        let index = draft.customFieldSchemas.count + 1
        draft.customFieldSchemas.append(CustomFieldSchema(key: "field_\(index)", displayName: "Field \(index)", kind: .text))
    }
}

private struct TemplateEditorValidationSection: View {
    let message: String?

    var body: some View {
        if let message {
            Section("Validation") {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .accessibilityLabel("Validation error: \(message)")
                    .accessibilityValue(message)
                    .accessibilityIdentifier("templates.editor.validation-error")
            }
        }
    }
}

struct TemplatePortEditor: View {
    @Binding var port: PortTemplate

    var body: some View {
        Form {
            TextField("Name", text: $port.name)
            Picker("Medium", selection: $port.medium) {
                ForEach(PortMedium.allCases, id: \.self) { medium in
                    Text(medium.rawValue).tag(medium)
                }
            }
            Picker("Connector", selection: $port.connector) {
                ForEach(connectors(for: port.medium), id: \.self) { connector in
                    Text(connector.rawValue).tag(connector)
                }
            }
            Picker("Face", selection: $port.face) {
                ForEach(PortFace.allCases, id: \.self) { face in
                    Text(face.rawValue).tag(face)
                }
            }
            Stepper("Order: \(port.order)", value: $port.order, in: 0...9_999)
        }
        .navigationTitle("Port")
        .onChange(of: port.medium) { _, medium in
            port.connector = connectors(for: medium).first ?? .other
            port.fiberMode = medium == .fiber ? .duplex : nil
        }
    }

    private func connectors(for medium: PortMedium) -> [Connector] {
        switch medium {
        case .copper: [.rj45]
        case .fiber: [.lc, .sc, .mpo]
        case .power: [.c13, .c14]
        case .other: [.other]
        }
    }
}

struct TemplateModuleSlotEditor: View {
    @Binding var slot: ModuleSlotTemplate
    let moduleTemplates: [ModuleTemplate]

    var body: some View {
        Form {
            TextField("Key", text: $slot.key)
                #if os(iOS)
                    .textInputAutocapitalization(.never)
                #endif
                .autocorrectionDisabled()
            TextField("Display name", text: $slot.displayName)
            Toggle("Required", isOn: $slot.isRequired)
            if moduleTemplates.isEmpty {
                ContentUnavailableView(
                    "No module templates",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Create a module template before assigning this slot.")
                )
            } else {
                ForEach(moduleTemplates) { template in
                    Toggle(template.name, isOn: allowedBinding(for: template.id))
                        .accessibilityIdentifier("templates.slot.allowed.\(template.id.description)")
                }
            }
        }
        .navigationTitle("Module slot")
    }

    private func allowedBinding(for id: ObjectID) -> Binding<Bool> {
        Binding(
            get: { slot.allowedModuleTemplateIDs.contains(id) },
            set: { isAllowed in
                if isAllowed {
                    if !slot.allowedModuleTemplateIDs.contains(id) { slot.allowedModuleTemplateIDs.append(id) }
                } else {
                    slot.allowedModuleTemplateIDs.removeAll { $0 == id }
                }
            }
        )
    }
}
