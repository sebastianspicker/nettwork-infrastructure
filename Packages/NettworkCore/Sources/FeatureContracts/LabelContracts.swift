import Foundation
import NetworkModel
import WorkspaceChangeControl

/// The intentionally small payload allowed on a physical label. The route is
/// derived rather than accepted from callers, so labels cannot carry mutable
/// topology text, addresses, credentials, or host names.
public struct PrivacySafeLabel: Identifiable, Equatable, Sendable {
    public let objectID: ObjectID
    public let assetCode: AssetCode
    public let checkText: String

    public init(objectID: ObjectID, assetCode: AssetCode, checkText: String) {
        self.objectID = objectID
        self.assetCode = assetCode
        self.checkText = checkText
    }

    public var id: ObjectID { objectID }
    public var opaqueRoute: URL { ObjectLink.url(for: objectID) }
}
public enum PrivacySafeLabelValidationError: LocalizedError, Equatable, Sendable {
    case invalidPayload
    case tooManyLabels
    case duplicateObjectID

    public var errorDescription: String? {
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

public enum PrivacySafeLabelValidator {
    public static let maximumLabels = 100
    public static let maximumAssetCodeLength = 64
    public static let maximumCheckTextLength = 16

    public static func validate(_ label: PrivacySafeLabel) throws {
        guard label.opaqueRoute == ObjectLink.url(for: label.objectID),
            isSafeToken(label.assetCode.value, maximumLength: maximumAssetCodeLength),
            label.assetCode == AssetCode(label.assetCode.value),
            isSafeToken(label.checkText, maximumLength: maximumCheckTextLength)
        else {
            throw PrivacySafeLabelValidationError.invalidPayload
        }
    }

    public static func validated(_ labels: [PrivacySafeLabel], limit: Int = maximumLabels) throws -> [PrivacySafeLabel] {
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
public protocol PrivacySafeLabelSourcing: Sendable {
    func labels(in namespace: PersistenceNamespace, limit: Int) async throws -> [PrivacySafeLabel]
}

public struct LabelSheetConfiguration: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var marginMillimeters: Double
    public var labelWidthMillimeters: Double
    public var labelHeightMillimeters: Double

    public init(
        columns: Int = 3,
        rows: Int = 7,
        marginMillimeters: Double = 6.0,
        labelWidthMillimeters: Double = 63.5,
        labelHeightMillimeters: Double = 38.1
    ) {
        self.columns = columns
        self.rows = rows
        self.marginMillimeters = marginMillimeters
        self.labelWidthMillimeters = labelWidthMillimeters
        self.labelHeightMillimeters = labelHeightMillimeters
    }
}

public struct LabelPDFDocument: Sendable {
    public let data: Data
    public let pageCount: Int

    public init(data: Data, pageCount: Int) {
        self.data = data
        self.pageCount = pageCount
    }
}

public protocol LabelPDFGenerating: Sendable {
    func makePDF(labels: [PrivacySafeLabel], configuration: LabelSheetConfiguration) async throws -> LabelPDFDocument
}

public protocol LabelPDFExporting: Sendable {
    func export(_ document: LabelPDFDocument) async throws
}

public protocol LabelPrinting: Sendable {
    func print(_ document: LabelPDFDocument) async throws
}
