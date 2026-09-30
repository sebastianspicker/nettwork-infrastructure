import CoreGraphics
import CoreImage
import CoreText
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

#if os(iOS)
    import UIKit
#elseif os(macOS)
    import AppKit
    import PDFKit
    import UniformTypeIdentifiers
#endif

enum PlatformLabelPDFError: LocalizedError {
    case invalidConfiguration
    case invalidLabel
    case renderingUnavailable
    case presentationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "The selected label-sheet dimensions do not fit on a page."
        case .invalidLabel: "A label does not satisfy the privacy-safe label contract."
        case .renderingUnavailable: "The QR label PDF could not be rendered."
        case .presentationUnavailable: "The export or print sheet cannot be presented from the current screen."
        }
    }
}

struct PlatformLabelPDFLayout {
    static let pointsPerMillimeter = 72.0 / 25.4
    static let pageSize = CGSize(width: 595, height: 842)  // ISO A4 in PostScript points.

    let columns: Int
    let rows: Int
    let margin: CGFloat
    let labelSize: CGSize

    init(configuration: LabelSheetConfiguration) throws {
        guard (1...5).contains(configuration.columns),
            (1...15).contains(configuration.rows),
            (2...25).contains(configuration.marginMillimeters),
            (20...100).contains(configuration.labelWidthMillimeters),
            (15...100).contains(configuration.labelHeightMillimeters)
        else {
            throw PlatformLabelPDFError.invalidConfiguration
        }
        let margin = configuration.marginMillimeters * Self.pointsPerMillimeter
        let labelSize = CGSize(
            width: configuration.labelWidthMillimeters * Self.pointsPerMillimeter, height: configuration.labelHeightMillimeters * Self.pointsPerMillimeter
        )
        guard labelSize.width * CGFloat(configuration.columns) + margin * 2 <= Self.pageSize.width,
            labelSize.height * CGFloat(configuration.rows) + margin * 2 <= Self.pageSize.height
        else {
            throw PlatformLabelPDFError.invalidConfiguration
        }
        self.columns = configuration.columns
        self.rows = configuration.rows
        self.margin = margin
        self.labelSize = labelSize
    }

    var labelsPerPage: Int { columns * rows }

    /// Converts a batch position to a page-local rect. Page-local positions
    /// prevent a label at a page boundary from accidentally drawing below A4.
    func rect(forPagePosition position: Int) -> CGRect {
        precondition((0..<labelsPerPage).contains(position))
        let row = position / columns
        let column = position % columns
        return CGRect(
            x: margin + CGFloat(column) * labelSize.width,
            y: margin + CGFloat(row) * labelSize.height,
            width: labelSize.width,
            height: labelSize.height
        )
    }

    func placement(forLabelAt index: Int) -> PlatformLabelPDFPlacement {
        precondition(index >= 0)
        return PlatformLabelPDFPlacement(
            pageIndex: index / labelsPerPage,
            rect: rect(forPagePosition: index % labelsPerPage)
        )
    }
}

struct PlatformLabelPDFPlacement: Equatable {
    let pageIndex: Int
    let rect: CGRect
}

/// Core Image and Core Graphics-only label producer. The generated QR payload is
/// the canonical opaque route; rendering intentionally has no access to asset
/// details, IP data, credentials, or topology records.
final class ProductionLabelPDFGenerator: @unchecked Sendable, LabelPDFGenerating {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    func makePDF(labels: [PrivacySafeLabel], configuration: LabelSheetConfiguration) async throws -> LabelPDFDocument {
        guard !labels.isEmpty else {
            throw PlatformLabelPDFError.invalidLabel
        }
        let layout = try PlatformLabelPDFLayout(configuration: configuration)
        let validatedLabels: [ValidatedLabel]
        do {
            validatedLabels = try PrivacySafeLabelValidator.validated(labels).map(ValidatedLabel.init)
        } catch {
            throw PlatformLabelPDFError.invalidLabel
        }
        let pageCount = Int(ceil(Double(validatedLabels.count) / Double(layout.labelsPerPage)))
        let data = try render(validatedLabels, layout: layout, pageCount: pageCount)
        return LabelPDFDocument(data: data, pageCount: pageCount)
    }

    func qrPayload(for label: PrivacySafeLabel) throws -> Data {
        try ValidatedLabel(label).qrPayload
    }

    private func render(_ labels: [ValidatedLabel], layout: PlatformLabelPDFLayout, pageCount: Int) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: PlatformLabelPDFLayout.pageSize)
        guard let consumer = CGDataConsumer(data: data),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            throw PlatformLabelPDFError.renderingUnavailable
        }

        for pageIndex in 0..<pageCount {
            context.beginPDFPage(nil)
            context.translateBy(x: 0, y: PlatformLabelPDFLayout.pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let start = pageIndex * layout.labelsPerPage
            let end = min(start + layout.labelsPerPage, labels.count)
            for labelIndex in start..<end {
                let placement = layout.placement(forLabelAt: labelIndex)
                guard placement.pageIndex == pageIndex else {
                    throw PlatformLabelPDFError.renderingUnavailable
                }
                try draw(labels[labelIndex], in: placement.rect, context: context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return Data(referencing: data)
    }

    private func draw(_ label: ValidatedLabel, in rect: CGRect, context: CGContext) throws {
        context.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
        context.setLineWidth(0.75)
        context.stroke(rect.insetBy(dx: 1, dy: 1))

        let qrSide = min(rect.height - 12, rect.width * 0.47)
        let qrRect = CGRect(x: rect.minX + 6, y: rect.minY + 6, width: qrSide, height: qrSide)
        try drawQRCode(label.qrPayload, in: qrRect, context: context)

        let textX = qrRect.maxX + 6
        let textWidth = rect.maxX - textX - 6
        drawText(label.assetCode, at: CGPoint(x: textX, y: rect.minY + 20), width: textWidth, size: 10, context: context)
        drawText(label.checkText, at: CGPoint(x: textX, y: rect.minY + 38), width: textWidth, size: 8, context: context)
        drawText(label.route, at: CGPoint(x: textX, y: rect.minY + 56), width: textWidth, size: 5.5, context: context)
    }

    private func drawQRCode(_ data: Data, in rect: CGRect, context: CGContext) throws {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else {
            throw PlatformLabelPDFError.renderingUnavailable
        }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else {
            throw PlatformLabelPDFError.renderingUnavailable
        }
        let moduleSize = image.extent.width
        let scale = floor(rect.width / moduleSize)
        guard scale >= 1 else { throw PlatformLabelPDFError.renderingUnavailable }
        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let rendered = ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            throw PlatformLabelPDFError.renderingUnavailable
        }
        context.interpolationQuality = .none
        context.draw(rendered, in: CGRect(x: rect.minX, y: rect.minY, width: moduleSize * scale, height: moduleSize * scale))
    }

    private func drawText(_ string: String, at point: CGPoint, width: CGFloat, size: CGFloat, context: CGContext) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 0, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        context.saveGState()
        context.clip(to: CGRect(x: point.x, y: point.y - size, width: width, height: size + 4))
        context.textPosition = point
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

private struct ValidatedLabel {
    let route: String
    let qrPayload: Data
    let assetCode: String
    let checkText: String

    init(_ label: PrivacySafeLabel) throws {
        guard label.opaqueRoute == ObjectLink.url(for: label.objectID) else {
            throw PlatformLabelPDFError.invalidLabel
        }
        do {
            try PrivacySafeLabelValidator.validate(label)
        } catch {
            throw PlatformLabelPDFError.invalidLabel
        }
        self.route = label.opaqueRoute.absoluteString
        self.qrPayload = Data(route.utf8)
        self.assetCode = label.assetCode.value
        self.checkText = label.checkText
    }
}

#if os(iOS)
    @MainActor
    final class PlatformLabelPDFExporter: LabelPDFExporting {
        private let presentationContext: IOSPresentationContext

        init(presentationContext: IOSPresentationContext) {
            self.presentationContext = presentationContext
        }

        func export(_ document: LabelPDFDocument) async throws {
            guard let presentation = presentationContext.presentingViewController else {
                throw PlatformLabelPDFError.presentationUnavailable
            }
            let url = try temporaryPDFURL(for: document)
            let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = presentation.view
                popover.sourceRect = CGRect(x: presentation.view.bounds.midX, y: presentation.view.bounds.midY, width: 1, height: 1)
            }
            await withCheckedContinuation { continuation in
                controller.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: url)
                    continuation.resume()
                }
                presentation.present(controller, animated: true)
            }
        }
    }

    @MainActor
    final class PlatformLabelPDFPrinter: LabelPrinting {
        private let presentationContext: IOSPresentationContext

        init(presentationContext: IOSPresentationContext) {
            self.presentationContext = presentationContext
        }

        func print(_ document: LabelPDFDocument) async throws {
            guard let presentation = presentationContext.presentingViewController else {
                throw PlatformLabelPDFError.presentationUnavailable
            }
            let controller = UIPrintInteractionController.shared
            let info = UIPrintInfo(dictionary: nil)
            info.jobName = "Nettwork Labels"
            info.outputType = .general
            controller.printInfo = info
            controller.printingItem = document.data
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                controller.present(from: presentation.view.bounds, in: presentation.view, animated: true) { _, _, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
    }
#elseif os(macOS)
    @MainActor
    final class PlatformLabelPDFExporter: LabelPDFExporting {
        func export(_ document: LabelPDFDocument) async throws {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = "Nettwork Labels.pdf"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try document.data.write(to: url, options: .atomic)
        }
    }

    @MainActor
    final class PlatformLabelPDFPrinter: LabelPrinting {
        func print(_ document: LabelPDFDocument) async throws {
            guard let view = PlatformPDFPrintView(data: document.data) else {
                throw PlatformLabelPDFError.renderingUnavailable
            }
            let operation = NSPrintOperation(view: view)
            operation.jobTitle = "Nettwork Labels"
            guard operation.run() else {
                throw PlatformLabelPDFError.presentationUnavailable
            }
        }
    }

    private final class PlatformPDFPrintView: NSView {
        private let document: PDFDocument

        init?(data: Data) {
            guard let document = PDFDocument(data: data), document.pageCount > 0 else { return nil }
            self.document = document
            super.init(frame: NSRect(origin: .zero, size: PlatformLabelPDFLayout.pageSize))
        }

        required init?(coder: NSCoder) { nil }

        override func knowsPageRange(_ range: NSRangePointer) -> Bool {
            range.pointee = NSRange(location: 1, length: document.pageCount)
            return true
        }

        override func rectForPage(_ page: Int) -> NSRect { bounds }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.white.setFill()
            bounds.fill()
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let pageIndex = max((NSPrintOperation.current?.currentPage ?? 1) - 1, 0)
            document.page(at: pageIndex)?.draw(with: .mediaBox, to: context)
        }
    }
#endif

private func temporaryPDFURL(for document: LabelPDFDocument) throws -> URL {
    guard document.data.starts(with: Data("%PDF".utf8)) else {
        throw PlatformLabelPDFError.renderingUnavailable
    }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("nettwork-labels-\(UUID().uuidString)")
        .appendingPathExtension("pdf")
    try document.data.write(to: url, options: .atomic)
    return url
}
