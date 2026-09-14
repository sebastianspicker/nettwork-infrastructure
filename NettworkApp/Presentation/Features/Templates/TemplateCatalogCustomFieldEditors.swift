import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct TemplateCustomFieldSchemaEditor: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var schema: CustomFieldSchema
    @Binding var values: [CustomFieldValue]
    @State private var key: String
    @State private var displayName: String
    @State private var kind: CustomFieldKind
    @State private var isRequired: Bool
    @State private var choices: String
    @State private var usesDefault: Bool
    @State private var textDefault: String
    @State private var numberDefault: Double
    @State private var flagDefault: Bool
    @State private var dateDefault: Date

    init(schema: Binding<CustomFieldSchema>, values: Binding<[CustomFieldValue]>) {
        _schema = schema
        _values = values
        let value = schema.wrappedValue
        _key = State(initialValue: value.key)
        _displayName = State(initialValue: value.displayName)
        _kind = State(initialValue: value.kind)
        _isRequired = State(initialValue: value.isRequired)
        _choices = State(initialValue: value.choices.joined(separator: ", "))
        _usesDefault = State(initialValue: value.defaultValue != nil)
        switch value.defaultValue {
        case .text(let text):
            _textDefault = State(initialValue: text)
            _numberDefault = State(initialValue: 0)
            _flagDefault = State(initialValue: false)
            _dateDefault = State(initialValue: .now)
        case .number(let number):
            _textDefault = State(initialValue: "")
            _numberDefault = State(initialValue: number)
            _flagDefault = State(initialValue: false)
            _dateDefault = State(initialValue: .now)
        case .flag(let flag):
            _textDefault = State(initialValue: "")
            _numberDefault = State(initialValue: 0)
            _flagDefault = State(initialValue: flag)
            _dateDefault = State(initialValue: .now)
        case .date(let date):
            _textDefault = State(initialValue: "")
            _numberDefault = State(initialValue: 0)
            _flagDefault = State(initialValue: false)
            _dateDefault = State(initialValue: date)
        case nil:
            _textDefault = State(initialValue: "")
            _numberDefault = State(initialValue: 0)
            _flagDefault = State(initialValue: false)
            _dateDefault = State(initialValue: .now)
        }
    }

    var body: some View {
        Form {
            #if os(iOS)
                TextField("Key", text: $key)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            #else
                TextField("Key", text: $key)
                    .autocorrectionDisabled()
            #endif
            TextField("Display name", text: $displayName)
            Picker("Type", selection: $kind) {
                ForEach(CustomFieldKind.allCases, id: \.self) { kind in Text(kind.rawValue).tag(kind) }
            }
            Toggle("Required", isOn: $isRequired)
            if kind == .choice {
                TextField("Choices", text: $choices, axis: .vertical).lineLimit(2...4)
                Text("Separate choices with commas.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Provide default value", isOn: $usesDefault)
            if usesDefault { defaultEditor }
        }
        .navigationTitle("Custom field")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                    dismiss()
                }
            }
        }
        .onChange(of: kind) { _, _ in usesDefault = false }
    }

    @ViewBuilder
    private var defaultEditor: some View {
        switch kind {
        case .text, .choice: TextField("Default value", text: $textDefault)
        case .number: TextField("Default value", value: $numberDefault, format: .number)
        case .flag: Toggle("Default value", isOn: $flagDefault)
        case .date: DatePicker("Default value", selection: $dateDefault, displayedComponents: .date)
        }
    }

    private func save() {
        let priorKey = schema.key
        let parsedChoices = choices.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !usesDefault {
            schema = CustomFieldSchema(key: key, displayName: displayName, kind: kind, isRequired: isRequired, choices: kind == .choice ? parsedChoices : [])
        } else {
            let defaultValue: CustomFieldValue.Value
            switch kind {
            case .text, .choice: defaultValue = .text(textDefault)
            case .number: defaultValue = .number(numberDefault)
            case .flag: defaultValue = .flag(flagDefault)
            case .date: defaultValue = .date(dateDefault)
            }
            schema = CustomFieldSchema(
                key: key,
                displayName: displayName,
                kind: kind,
                isRequired: isRequired,
                defaultValue: defaultValue,
                choices: kind == .choice ? parsedChoices : []
            )
        }

        let priorValue = values.first(where: { $0.key == priorKey })
        values.removeAll { $0.key == priorKey }
        if let priorValue {
            values.append(CustomFieldValue(key: schema.key, value: priorValue.value))
        }
    }
}

struct TemplateCustomFieldValueEditor: View {
    @Environment(\.dismiss) private var dismiss

    let schema: CustomFieldSchema
    @Binding var values: [CustomFieldValue]
    @State private var includesValue: Bool
    @State private var textValue: String
    @State private var numberValue: Double
    @State private var flagValue: Bool
    @State private var dateValue: Date

    init(schema: CustomFieldSchema, values: Binding<[CustomFieldValue]>) {
        self.schema = schema
        _values = values
        let existing = values.wrappedValue.first(where: { $0.key == schema.key })?.value
        _includesValue = State(initialValue: existing != nil)
        switch existing {
        case .text(let text):
            _textValue = State(initialValue: text)
            _numberValue = State(initialValue: 0)
            _flagValue = State(initialValue: false)
            _dateValue = State(initialValue: .now)
        case .number(let number):
            _textValue = State(initialValue: "")
            _numberValue = State(initialValue: number)
            _flagValue = State(initialValue: false)
            _dateValue = State(initialValue: .now)
        case .flag(let flag):
            _textValue = State(initialValue: "")
            _numberValue = State(initialValue: 0)
            _flagValue = State(initialValue: flag)
            _dateValue = State(initialValue: .now)
        case .date(let date):
            _textValue = State(initialValue: "")
            _numberValue = State(initialValue: 0)
            _flagValue = State(initialValue: false)
            _dateValue = State(initialValue: date)
        case nil:
            _textValue = State(initialValue: "")
            _numberValue = State(initialValue: 0)
            _flagValue = State(initialValue: false)
            _dateValue = State(initialValue: .now)
        }
    }

    var body: some View {
        Form {
            Text(schema.kind.rawValue.capitalized).foregroundStyle(.secondary)
            Toggle("Set an explicit value", isOn: $includesValue)
            if includesValue {
                valueEditor
            } else if let defaultValue = schema.defaultValue {
                LabeledContent("Schema default", value: defaultValue.description)
            }
        }
        .navigationTitle(schema.displayName)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                    dismiss()
                }
            }
        }
    }

    @ViewBuilder
    private var valueEditor: some View {
        switch schema.kind {
        case .text: TextField("Value", text: $textValue)
        case .choice:
            Picker("Value", selection: $textValue) {
                ForEach(schema.choices, id: \.self) { choice in Text(choice).tag(choice) }
            }
        case .number: TextField("Value", value: $numberValue, format: .number)
        case .flag: Toggle("Value", isOn: $flagValue)
        case .date: DatePicker("Value", selection: $dateValue, displayedComponents: .date)
        }
    }

    private func save() {
        values.removeAll { $0.key == schema.key }
        guard includesValue else { return }
        let value: CustomFieldValue.Value
        switch schema.kind {
        case .text, .choice: value = .text(textValue)
        case .number: value = .number(numberValue)
        case .flag: value = .flag(flagValue)
        case .date: value = .date(dateValue)
        }
        values.append(CustomFieldValue(key: schema.key, value: value))
    }
}
