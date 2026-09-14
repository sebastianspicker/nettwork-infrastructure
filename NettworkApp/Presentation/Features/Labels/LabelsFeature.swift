import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

/// The intentionally small payload allowed on a physical label. The route is
/// derived rather than accepted from callers, so labels cannot carry mutable
/// topology text, addresses, credentials, or host names.
struct PrivacySafeLabel: Identifiable, Equatable, Sendable {
    let objectID: ObjectID
    let assetCode: AssetCode
    let checkText: String

    var id: ObjectID { objectID }
    var opaqueRoute: URL { ObjectLink.url(for: objectID) }
}
enum PrivacySafeLabelValidationError: LocalizedError, Equatable, Sendable {
    case invalidPayload
    case tooManyLabels
    case duplicateObjectID

    var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "A label payload must contain one canonical object route, a validated asset code, and bounded check text."
        case .tooManyLabels:
            "The label request exceeds the maximum sheet batch size."
        case .duplicateObjectID:
            "A label source returned the same object more than once."
        }
    }
}

enum PrivacySafeLabelValidator {
    static let maximumLabels = 100
    static let maximumAssetCodeLength = 64
    static let maximumCheckTextLength = 16

    static func validate(_ label: PrivacySafeLabel) throws {
        guard label.opaqueRoute == ObjectLink.url(for: label.objectID),
            isSafeToken(label.assetCode.value, maximumLength: maximumAssetCodeLength),
            label.assetCode == AssetCode(label.assetCode.value),
            isSafeToken(label.checkText, maximumLength: maximumCheckTextLength)
        else {
            throw PrivacySafeLabelValidationError.invalidPayload
        }
    }

    static func validated(_ labels: [PrivacySafeLabel], limit: Int = maximumLabels) throws -> [PrivacySafeLabel] {
        guard labels.count <= min(max(limit, 1), maximumLabels) else {
            throw PrivacySafeLabelValidationError.tooManyLabels
        }
        var seen = Set<ObjectID>()
        for label in labels {
            guard seen.insert(label.objectID).inserted else {
                throw PrivacySafeLabelValidationError.duplicateObjectID
            }
            try validate(label)
        }
        return labels.sorted { lhs, rhs in
            if lhs.assetCode != rhs.assetCode { return lhs.assetCode < rhs.assetCode }
            return lhs.objectID < rhs.objectID
        }
    }

    private static func isSafeToken(_ value: String, maximumLength: Int) -> Bool {
        guard !value.isEmpty, value.count <= maximumLength else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains(scalar)
        }
    }
}

/// A source exposes a bounded, account-scoped projection. It must never expose
/// or accept mutable topology data as label input.
protocol PrivacySafeLabelSourcing: Sendable {
    func labels(in namespace: PersistenceNamespace, limit: Int) async throws -> [PrivacySafeLabel]
}

struct LabelSheetConfiguration: Equatable, Sendable {
    var columns = 3
    var rows = 7
    var marginMillimeters = 6.0
    var labelWidthMillimeters = 63.5
    var labelHeightMillimeters = 38.1
}

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

struct LabelPDFDocument: Sendable {
    let data: Data
    let pageCount: Int
}

protocol LabelPDFGenerating: Sendable {
    func makePDF(labels: [PrivacySafeLabel], configuration: LabelSheetConfiguration) async throws -> LabelPDFDocument
}

protocol LabelPDFExporting: Sendable {
    func export(_ document: LabelPDFDocument) async throws
}

protocol LabelPrinting: Sendable {
    func print(_ document: LabelPDFDocument) async throws
}

@MainActor
@Observable
final class LabelSheetModel {
    private let account: AccountContext
    private let source: any PrivacySafeLabelSourcing
    private let generator: any LabelPDFGenerating
    private let exporter: any LabelPDFExporting
    private let printer: any LabelPrinting

    var configuration = LabelSheetConfiguration() {
        didSet {
            selectedPreset = LabelSheetPreset.matching(configuration)
            document = nil
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
        state = .loading
        document = nil
        do {
            labels = try PrivacySafeLabelValidator.validated(
                await source.labels(in: account.namespace, limit: PrivacySafeLabelValidator.maximumLabels)
            )
            selectedObjectIDs = Set(labels.map(\.objectID))
            state = labels.isEmpty ? .empty : .ready
        } catch is CancellationError {
            return
        } catch is PrivacySafeLabelValidationError {
            labels = []
            selectedObjectIDs = []
            state = .quarantined("The label source returned a payload outside the privacy-safe label contract.")
        } catch {
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
        document = nil
    }

    func selectAll() {
        selectedObjectIDs = Set(labels.map(\.objectID))
        document = nil
    }

    func clearSelection() {
        selectedObjectIDs = []
        document = nil
    }

    func generate() async {
        guard !selectedLabels.isEmpty else {
            state = .unavailable("Select at least one privacy-safe label before generating a PDF.")
            return
        }
        do {
            document = try await generator.makePDF(labels: selectedLabels, configuration: configuration)
            state = .ready
        } catch is CancellationError {
            return
        } catch {
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
