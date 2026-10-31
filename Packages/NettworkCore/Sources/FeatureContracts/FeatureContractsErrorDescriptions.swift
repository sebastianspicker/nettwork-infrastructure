import Foundation

extension FloorPlanPDFInspectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidPageCount:
            "The floor plan PDF has no pages or too many pages. Choose a PDF with a reasonable number of pages."
        }
    }
}
