import ContentSafety
import Foundation
import NetworkModel
import PDFKit
import WorkspaceChangeControl

enum ProductionFloorPlanPDFInspectorError: Error, Equatable, Sendable {
    case unauthorized
    case invalidMetadata
    case invalidChunk
    case invalidSignature
    case invalidDocument
    case invalidPageBoxes
}

/// Reads only the importer-owned opaque capability, with the same byte/page/
/// geometry bounds enforced by ContentSafety before the user is offered a page
/// choice. The source is read again by sanitization; no inspection bytes or URL
/// escape this adapter.
struct ProductionFloorPlanPDFInspector: FloorPlanPDFInspecting {
    private static let chunkLimit = 64 * 1_024
    private let currentContext: any CurrentAuthorizationContextProviding

    init(currentContext: any CurrentAuthorizationContextProviding) {
        self.currentContext = currentContext
    }

    func inspectPDF(source: any OpaqueContentSource, authorization: AuthorizedOperationContext) async throws -> FloorPlanPDFInspection {
        guard authorization.action == .createAttachment,
            await currentContext.validateCurrent(authorization)
        else {
            throw ProductionFloorPlanPDFInspectorError.unauthorized
        }
        let metadata = try source.metadata()
        guard metadata.declaredType == .pdf,
            metadata.byteCount > 0,
            metadata.byteCount <= ContentSafetyService.maximumRawPDFBytes
        else {
            throw ProductionFloorPlanPDFInspectorError.invalidMetadata
        }
        let bytes = try readBytes(source, expectedCount: metadata.byteCount)
        let document = try validatedDocument(bytes)
        try validatePageBoxes(document)
        guard await currentContext.validateCurrent(authorization) else {
            throw ProductionFloorPlanPDFInspectorError.unauthorized
        }
        return try FloorPlanPDFInspection(pageCount: document.pageCount)
    }

    private func readBytes(_ source: any OpaqueContentSource, expectedCount: Int) throws -> Data {
        var reader = try source.makeReader()
        var bytes = Data()
        while let chunk = try reader.nextChunk(maximumBytes: Self.chunkLimit) {
            guard !chunk.isEmpty,
                chunk.count <= Self.chunkLimit,
                bytes.count <= ContentSafetyService.maximumRawPDFBytes - chunk.count
            else {
                throw ProductionFloorPlanPDFInspectorError.invalidChunk
            }
            bytes.append(chunk)
        }
        guard bytes.count == expectedCount else {
            throw ProductionFloorPlanPDFInspectorError.invalidMetadata
        }
        return bytes
    }

    private func validatedDocument(_ bytes: Data) throws -> PDFDocument {
        guard bytes.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) else {
            throw ProductionFloorPlanPDFInspectorError.invalidSignature
        }
        guard let document = PDFDocument(data: bytes),
            (1...ContentSafetyService.maximumPDFPages).contains(document.pageCount)
        else {
            throw ProductionFloorPlanPDFInspectorError.invalidDocument
        }
        return document
    }

    private func validatePageBoxes(_ document: PDFDocument) throws {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else {
                throw ProductionFloorPlanPDFInspectorError.invalidDocument
            }
            for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] {
                let bounds = page.bounds(for: box)
                guard bounds.origin.x.isFinite,
                    bounds.origin.y.isFinite,
                    bounds.width.isFinite,
                    bounds.height.isFinite,
                    bounds.width > 0,
                    bounds.height > 0,
                    bounds.width <= CGFloat(ContentSafetyService.maximumPDFBoxPoints),
                    bounds.height <= CGFloat(ContentSafetyService.maximumPDFBoxPoints)
                else {
                    throw ProductionFloorPlanPDFInspectorError.invalidPageBoxes
                }
            }
        }
    }
}
