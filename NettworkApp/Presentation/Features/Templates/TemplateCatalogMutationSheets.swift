import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct ModuleTemplateEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let route: ModuleTemplateEditorRoute
    @Bindable var model: TemplateCatalogModel
    @State private var draft: ModuleTemplate
    @State private var title: String
    @State private var ticketID = ""
    @State private var notes = ""
    @State private var validationMessage: String?
    @State private var isStaging = false

    init(route: ModuleTemplateEditorRoute, model: TemplateCatalogModel) {
        self.route = route
        self.model = model
        _draft = State(initialValue: route.initialTemplate())
        _title = State(initialValue: route.title)
    }

    var body: some View {
        NavigationStack {
            Form {
                TemplateChangeRequestSection(title: $title, ticketID: $ticketID, notes: $notes)
                Section("Module template") {
                    TextField("Name", text: $draft.name)
                    LabeledContent("Version", value: "\(draft.version)")
                }
                Section("Ports") {
                    ForEach($draft.ports) { $port in
                        NavigationLink(port.name.isEmpty ? "Unnamed port" : port.name) { TemplatePortEditor(port: $port) }
                    }
                    .onDelete { draft.ports.remove(atOffsets: $0) }
                    Button {
                        let order = (draft.ports.map(\.order).max() ?? -1) + 1
                        draft.ports.append(PortTemplate(name: "Port \(order + 1)", medium: .copper, connector: .rj45, order: order))
                    } label: {
                        Label("Add port", systemImage: "plus")
                    }
                }
                if let validationMessage {
                    Section("Validation") {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityStatus(validationMessage, identifier: "templates.module-editor.validation-error")
                    }
                }
            }
            .navigationTitle(route.title)
            .platformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStaging ? "Staging…" : "Stage request") { stageRequest() }
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
            validationMessage = "Module template name is required."
            return
        }
        do {
            try TemplateCatalog.validate(moduleTemplate: draft)
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
            return
        }
        isStaging = true
        let request = ModuleTemplateChangeRequest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            ticketID: ticketID.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            targetTemplate: draft,
            requestKind: route.requestKind
        )
        Task {
            let staged = await model.stage(request)
            isStaging = false
            if staged != nil {
                dismiss()
            }
        }
    }
}

struct TemplateInstantiationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let template: DeviceType
    let moduleTemplates: [ModuleTemplate]
    @Bindable var model: TemplateCatalogModel
    @State private var title = "Install template device"
    @State private var ticketID = ""
    @State private var notes = ""
    @State private var assetCode = ""
    @State private var deviceName = ""
    @State private var selectedModuleIDs: [String: ObjectID] = [:]
    @State private var validationMessage: String?
    @State private var isStaging = false

    var body: some View {
        NavigationStack {
            Form {
                TemplateChangeRequestSection(title: $title, ticketID: $ticketID, notes: $notes)
                Section("Device") {
                    TextField("Asset code", text: $assetCode).uppercaseIDInputFormatting()
                    TextField("Device name", text: $deviceName)
                    LabeledContent("Template", value: "\(template.name) v\(template.version)")
                }
                Section("Module choices") {
                    ForEach(template.moduleSlots, id: \.key) { slot in
                        let choices = moduleTemplates.filter { slot.allowedModuleTemplateIDs.contains($0.id) }
                        if choices.isEmpty {
                            Label("\(slot.displayName): no persisted allowed module templates", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .accessibilityStatus(
                                    "\(slot.displayName) has no persisted allowed module templates.",
                                    identifier: "templates.instantiate.module-options-error"
                                )
                        } else {
                            Picker(slot.displayName, selection: moduleSelection(for: slot.key)) {
                                if !slot.isRequired { Text("Not installed").tag(ObjectID?.none) }
                                ForEach(choices) { choice in Text("\(choice.name) v\(choice.version)").tag(Optional(choice.id)) }
                            }
                        }
                    }
                }
                if let validationMessage {
                    Section("Validation") {
                        Label(validationMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                            .accessibilityStatus(validationMessage, identifier: "templates.instantiate.validation-error")
                    }
                }
            }
            .navigationTitle("Instantiate device")
            .platformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStaging ? "Staging…" : "Stage installation") { stageInstallation() }
                        .disabled(
                            isStaging
                                || assetCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || deviceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || ticketID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        )
                }
            }
        }
    }

    private func moduleSelection(for slot: String) -> Binding<ObjectID?> {
        Binding(get: { selectedModuleIDs[slot] }, set: { value in selectedModuleIDs[slot] = value })
    }

    private func stageInstallation() {
        let selected = Dictionary(
            uniqueKeysWithValues: selectedModuleIDs.compactMap { slot, id in
                moduleTemplates.first(where: { $0.id == id }).map { (slot, $0) }
            })
        let allPorts = template.portTemplates + selected.values.flatMap(\.ports)
        var portIDs: [ObjectID: ObjectID] = [:]
        for port in allPorts {
            guard portIDs[port.id] == nil else {
                validationMessage = "A selected module reuses a port-template ID. Choose a module template with distinct port identities."
                return
            }
            portIDs[port.id] = ObjectID()
        }
        let request = DeviceInstantiationRequest(
            deviceID: ObjectID(), assetCode: AssetCode(assetCode), name: deviceName,
            modulesBySlot: selected,
            moduleIDsBySlot: Dictionary(uniqueKeysWithValues: selected.keys.map { ($0, ObjectID()) }),
            portIDsByTemplateID: portIDs
        )
        do {
            let installed = try TemplateInstantiator.instantiate(template: template, request: request)
            validationMessage = nil
            isStaging = true
            let change = TemplateChangeRequest(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                ticketID: ticketID.trimmingCharacters(in: .whitespacesAndNewlines),
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                targetTemplate: template,
                requestKind: .instantiate(installed)
            )
            Task {
                let staged = await model.stage(change)
                isStaging = false
                if staged != nil {
                    dismiss()
                }
            }
        } catch {
            validationMessage = error.localizedDescription
        }
    }
}

struct TemplateMigrationDecisionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let template: DeviceType
    let plans: [DeviceTemplateMigrationPlan]
    @Bindable var model: TemplateCatalogModel
    @State private var title = "Migrate template version"
    @State private var ticketID = ""
    @State private var notes = ""
    @State private var selectedDeviceIDs: Set<ObjectID>
    @State private var cableReviewAcknowledged = false
    @State private var isStaging = false

    init(template: DeviceType, plans: [DeviceTemplateMigrationPlan], model: TemplateCatalogModel) {
        self.template = template
        self.plans = plans
        self.model = model
        _selectedDeviceIDs = State(initialValue: Set(plans.map(\.deviceID)))
    }

    private var selectedPlans: [DeviceTemplateMigrationPlan] {
        plans.filter { selectedDeviceIDs.contains($0.deviceID) }
    }

    private var requiresCableReview: Bool {
        selectedPlans.flatMap(\.portImpacts).contains(where: \.requiresCableReview)
    }

    var body: some View {
        NavigationStack {
            Form {
                TemplateChangeRequestSection(title: $title, ticketID: $ticketID, notes: $notes)
                Section("Affected devices") {
                    ForEach(plans, id: \.deviceID) { plan in
                        Toggle(isOn: selectionBinding(for: plan.deviceID)) {
                            VStack(alignment: .leading) {
                                Text(plan.deviceID.description).font(.footnote.monospaced())
                                Text("\(plan.portImpacts.count) port impacts").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if requiresCableReview {
                    Section("Cable review") {
                        Toggle("I have reviewed the affected cable impacts", isOn: $cableReviewAcknowledged)
                    }
                }
            }
            .navigationTitle("Migration decisions")
            .platformInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isStaging ? "Staging…" : "Stage decisions") { stageDecisions() }
                        .disabled(
                            isStaging
                                || selectedPlans.isEmpty
                                || ticketID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                || (requiresCableReview && !cableReviewAcknowledged)
                        )
                }
            }
        }
    }

    private func selectionBinding(for id: ObjectID) -> Binding<Bool> {
        Binding(
            get: { selectedDeviceIDs.contains(id) },
            set: { selected in
                if selected { selectedDeviceIDs.insert(id) } else { selectedDeviceIDs.remove(id) }
            }
        )
    }

    private func stageDecisions() {
        isStaging = true
        let request = TemplateChangeRequest(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            ticketID: ticketID.trimmingCharacters(in: .whitespacesAndNewlines),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            targetTemplate: template,
            requestKind: .migration(plans: selectedPlans)
        )
        Task {
            let stagedID = await model.stage(request)
            isStaging = false
            if stagedID != nil { dismiss() }
        }
    }
}

private struct TemplateChangeRequestSection: View {
    @Binding var title: String
    @Binding var ticketID: String
    @Binding var notes: String

    var body: some View {
        Section("Request") {
            TextField("Request title", text: $title)
            TextField("Change ticket", text: $ticketID).uppercaseIDInputFormatting()
            TextField("Review notes", text: $notes, axis: .vertical).lineLimit(3...6)
        }
    }
}

extension CustomFieldValue.Value {
    var description: String {
        switch self {
        case .text(let value): value
        case .number(let value): value.formatted()
        case .flag(let value): value ? "Yes" : "No"
        case .date(let value): value.formatted(date: .abbreviated, time: .omitted)
        }
    }
}

private extension View {
    @ViewBuilder
    func uppercaseIDInputFormatting() -> some View {
        #if os(iOS)
            textInputAutocapitalization(.characters).autocorrectionDisabled()
        #else
            autocorrectionDisabled()
        #endif
    }

    @ViewBuilder
    func platformInlineNavigationTitle() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }
}
