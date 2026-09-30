import ContentSafety
import CoreGraphics
import FeatureContracts
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

enum FloorPlanAttachmentState: Equatable {
    case idle
    case inspectingPDF
    case awaitingPDFPageSelection(FloorPlanPDFInspection)
    case sanitizing
    case staged(SanitizedContentDescriptor)
    case cleaningUp
    case failed(String)
}

enum FloorPlanPreviewState {
    case idle
    case loading
    case rendered(FloorPlanPreview)
    case cancelled
    case failed(String)
}
