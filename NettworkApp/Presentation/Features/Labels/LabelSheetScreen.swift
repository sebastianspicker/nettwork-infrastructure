import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

struct LabelSheetScreen: View {
    @Bindable var model: LabelSheetModel
    let statusAnnouncer: any AccessibilityStatusAnnouncing

    @MainActor init(
        model: LabelSheetModel,
        statusAnnouncer: any AccessibilityStatusAnnouncing = AccessibilityStatusAnnouncer()
    ) {
        self.model = model
        self.statusAnnouncer = statusAnnouncer
    }

    var body: some View {
        Form {
            Section {
                NettworkPageHeader(
                    "Labels",
                    subtitle: "Choose privacy-safe labels, check the layout, then generate a PDF for export or printing.",
                    systemImage: "tag"
                )
            }
            LabelSheetStateMessage(state: model.state)
            layoutSection
            selectionSection
            previewSection
            actionsSection
        }
        .navigationTitle("Labels")
        .task { await model.load() }
        .onChange(of: model.state) { _, state in
            statusAnnouncer.announce(labelSheetStatus(state))
        }
    }

    private func labelSheetStatus(_ state: InventoryPresentationState) -> String {
        switch state {
        case .loading: "Loading privacy-safe labels."
        case .ready: "Privacy-safe labels are ready."
        case .empty: "No privacy-safe labels are available in this workspace."
        case .offline(let message), .pending(let message), .conflict(let message),
            .quarantined(let message), .permissionDenied(let message), .unavailable(let message):
            message
        }
    }

    private var layoutSection: some View {
        Section("Layout") {
            Picker("Preset", selection: $model.selectedPreset) {
                ForEach(LabelSheetPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .onChange(of: model.selectedPreset) { _, preset in model.applyPreset(preset) }
            .accessibilityIdentifier("labels.preset")
            Stepper("Columns: \(model.configuration.columns)", value: $model.configuration.columns, in: 1...5)
                .accessibilityIdentifier("labels.columns")
            Stepper("Rows: \(model.configuration.rows)", value: $model.configuration.rows, in: 1...15)
                .accessibilityIdentifier("labels.rows")
            Stepper(
                "Margin: \(model.configuration.marginMillimeters, format: .number.precision(.fractionLength(1))) mm",
                value: $model.configuration.marginMillimeters,
                in: 2...25,
                step: 0.5
            )
            .accessibilityIdentifier("labels.margin")
            Stepper(
                "Width: \(model.configuration.labelWidthMillimeters, format: .number.precision(.fractionLength(1))) mm",
                value: $model.configuration.labelWidthMillimeters,
                in: 20...100,
                step: 0.5
            )
            .accessibilityIdentifier("labels.width")
            Stepper(
                "Height: \(model.configuration.labelHeightMillimeters, format: .number.precision(.fractionLength(1))) mm",
                value: $model.configuration.labelHeightMillimeters,
                in: 15...100,
                step: 0.5
            )
            .accessibilityIdentifier("labels.height")
            Text("Labels contain an opaque object route, asset code, and check text only. They never include IPs, hostnames, credentials, or mutable topology.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var selectionSection: some View {
        Section("Selection") {
            HStack {
                Button("Select all", action: model.selectAll)
                    .accessibilityIdentifier("labels.select-all")
                Spacer()
                Button("Clear selection", action: model.clearSelection)
                    .accessibilityIdentifier("labels.clear-selection")
            }
            Text("\(model.selectedLabels.count) of \(model.labels.count) labels selected")
                .accessibilityIdentifier("labels.selection-count")
                .foregroundStyle(.secondary)
                .accessibilityValue("\(model.selectedLabels.count) selected out of \(model.labels.count)")
        }
    }

    private var previewSection: some View {
        Section("Preview") {
            Text("Select only the labels needed for this run. The preview shows the privacy-safe content used for PDF generation.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if model.labels.isEmpty {
                Text("Load a scoped label source to preview available labels.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.labels) { label in
                    Button {
                        model.toggleSelection(for: label)
                    } label: {
                        LabelPreview(label: label, isSelected: model.selectedObjectIDs.contains(label.objectID))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("labels.selection")
                    .accessibilityLabel("\(label.assetCode.value), check \(label.checkText)")
                    .accessibilityValue(model.selectedObjectIDs.contains(label.objectID) ? "Selected" : "Not selected")
                    .accessibilityHint("Double tap to toggle this label for PDF generation.")
                }
            }
        }
    }

    private var actionsSection: some View {
        Section("Generate and deliver") {
            Text("Generate a PDF after selecting labels. Export and print are available once that document is ready.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("Generate PDF") { Task { await model.generate() } }
                .disabled(model.selectedLabels.isEmpty)
                .accessibilityIdentifier("labels.generate")
            Button("Export PDF") { Task { await model.export() } }
                .disabled(model.document == nil)
                .accessibilityIdentifier("labels.export")
            Button("Print labels") { Task { await model.printLabels() } }
                .disabled(model.document == nil)
                .accessibilityIdentifier("labels.print")
        }
    }
}

private struct LabelPreview: View {
    let label: PrivacySafeLabel
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "qrcode")
                .font(.title2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.assetCode.value).font(.headline)
                Text(label.checkText).font(.footnote)
                Text(label.opaqueRoute.absoluteString)
                    .font(.caption2.monospaced())
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
    }
}

@ViewBuilder
@MainActor
private func LabelSheetStateMessage(state: InventoryPresentationState) -> some View {
    switch state {
    case .loading:
        NettworkLoadingState("Loading privacy-safe labels")
    case .ready:
        EmptyView()
    case .empty:
        ContentUnavailableView("No labels available", systemImage: "tag.slash", description: Text("No privacy-safe labels are available in this workspace."))
            .accessibilityStatus("No privacy-safe labels are available in this workspace.", identifier: "labels.status.empty")
    case .offline(let message), .unavailable(let message):
        ContentUnavailableView("Labels unavailable", systemImage: "wifi.exclamationmark", description: Text(message))
            .accessibilityStatus(message, identifier: "labels.status.unavailable")
    case .pending(let message):
        Label(message, systemImage: "clock.badge.checkmark")
            .foregroundStyle(.secondary)
            .accessibilityStatus(message, identifier: "labels.status.pending")
    case .conflict(let message), .quarantined(let message), .permissionDenied(let message):
        Label(message, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.red)
            .accessibilityStatus(message, identifier: "labels.status.error")
    }
}
