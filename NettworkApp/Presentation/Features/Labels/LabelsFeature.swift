import FeatureContracts
import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

enum LabelSheetPreset: String, CaseIterable, Identifiable, Sendable {
    case compact
    case standard
    case large
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: "Compact"
        case .standard: "Standard"
        case .large: "Large"
        case .custom: "Custom"
        }
    }

    var configuration: LabelSheetConfiguration? {
        switch self {
        case .compact:
            LabelSheetConfiguration(columns: 5, rows: 12, marginMillimeters: 4, labelWidthMillimeters: 38, labelHeightMillimeters: 20)
        case .standard:
            LabelSheetConfiguration()
        case .large:
            LabelSheetConfiguration(columns: 2, rows: 5, marginMillimeters: 8, labelWidthMillimeters: 90, labelHeightMillimeters: 50)
        case .custom:
            nil
        }
    }

    static func matching(_ configuration: LabelSheetConfiguration) -> Self {
        allCases.first(where: { $0.configuration == configuration }) ?? .custom
    }
}

@MainActor
@Observable
final class LabelSheetModel {
    private var loadGeneration: UInt64 = 0
    private var documentGeneration: UInt64 = 0
    private let account: AccountContext
    private let source: any PrivacySafeLabelSourcing
    private let generator: any LabelPDFGenerating
    private let exporter: any LabelPDFExporting
    private let printer: any LabelPrinting

    var configuration = LabelSheetConfiguration() {
        didSet {
            selectedPreset = LabelSheetPreset.matching(configuration)
            invalidateDocument()
        }
    }
    var selectedPreset: LabelSheetPreset = .standard
    private(set) var labels: [PrivacySafeLabel] = []
    private(set) var selectedObjectIDs = Set<ObjectID>()
    private(set) var state: InventoryPresentationState = .loading
    private(set) var document: LabelPDFDocument?

    init(
        account: AccountContext,
        source: any PrivacySafeLabelSourcing,
        generator: any LabelPDFGenerating,
        exporter: any LabelPDFExporting,
        printer: any LabelPrinting
    ) {
        self.account = account
        self.source = source
        self.generator = generator
        self.exporter = exporter
        self.printer = printer
    }

    var selectedLabels: [PrivacySafeLabel] {
        labels.filter { selectedObjectIDs.contains($0.objectID) }
    }

    func load() async {
        guard !Task.isCancelled else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        invalidateDocument()
        labels = []
        selectedObjectIDs = []
        state = .loading
        do {
            let loaded = try PrivacySafeLabelValidator.validated(
                await source.labels(in: account.namespace, limit: PrivacySafeLabelValidator.maximumLabels)
            )
            guard generation == loadGeneration, !Task.isCancelled else { return }
            labels = loaded
            selectedObjectIDs = Set(labels.map(\.objectID))
            state = labels.isEmpty ? .empty : .ready
        } catch is CancellationError {
            return
        } catch is PrivacySafeLabelValidationError {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            labels = []
            selectedObjectIDs = []
            state = .quarantined("The label source returned a payload outside the privacy-safe label contract.")
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            labels = []
            selectedObjectIDs = []
            state = .offline("Labels are unavailable from the scoped local mirror.")
        }
    }

    func applyPreset(_ preset: LabelSheetPreset) {
        guard let configuration = preset.configuration else { return }
        self.configuration = configuration
        selectedPreset = preset
    }

    func toggleSelection(for label: PrivacySafeLabel) {
        if selectedObjectIDs.contains(label.objectID) {
            selectedObjectIDs.remove(label.objectID)
        } else {
            selectedObjectIDs.insert(label.objectID)
        }
        invalidateDocument()
    }

    func selectAll() {
        selectedObjectIDs = Set(labels.map(\.objectID))
        invalidateDocument()
    }

    func clearSelection() {
        selectedObjectIDs = []
        invalidateDocument()
    }

    private func invalidateDocument() {
        documentGeneration &+= 1
        document = nil
    }

    func generate() async {
        guard !Task.isCancelled else { return }
        invalidateDocument()
        let generation = documentGeneration
        let requestedLabels = selectedLabels
        let requestedConfiguration = configuration
        guard !requestedLabels.isEmpty else {
            state = .unavailable("Select at least one privacy-safe label before generating a PDF.")
            return
        }
        do {
            let generated = try await generator.makePDF(labels: requestedLabels, configuration: requestedConfiguration)
            guard generation == documentGeneration, !Task.isCancelled else { return }
            document = generated
            state = .ready
        } catch is CancellationError {
            return
        } catch {
            guard generation == documentGeneration, !Task.isCancelled else { return }
            state = .quarantined("The PDF could not be produced. Labels include only opaque routes, asset codes, and check text.")
        }
    }

    func export() async {
        guard let document else {
            state = .unavailable("Generate a PDF before exporting it.")
            return
        }
        do {
            try await exporter.export(document)
        } catch is CancellationError {
            return
        } catch {
            state = .offline("PDF export is unavailable on this device.")
        }
    }

    func printLabels() async {
        guard let document else {
            state = .unavailable("Generate a PDF before printing it.")
            return
        }
        do {
            try await printer.print(document)
        } catch is CancellationError {
            return
        } catch {
            state = .permissionDenied("Printing is unavailable or was not authorized.")
        }
    }
}
