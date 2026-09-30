import ContentSafety
import CoreGraphics
import FeatureContracts
import Foundation
import ImageIO
import NetworkModel
import Persistence
import UniformTypeIdentifiers
import WorkspaceChangeControl

enum ProductionFloorPlanPreviewRenderingError: LocalizedError, Equatable, Sendable {
    case unauthorized
    case invalidDescriptor
    case stagingMismatch
    case invalidSanitizedJPEG
    case previewBoundsExceeded

    var errorDescription: String? {
        switch self {
        case .unauthorized: "The current account session cannot display this floor plan."
        case .invalidDescriptor, .stagingMismatch: "The sanitized floor plan is no longer available."
        case .invalidSanitizedJPEG: "The staged floor plan preview is not a valid sanitized JPEG."
        case .previewBoundsExceeded: "The staged floor plan exceeds the preview safety limits."
        }
    }
}

private struct BoundedFloorPlanPreviewDecodingInput: Sendable {
    let jpegData: Data
    let expectedByteCount: Int
    let expectedPixelWidth: Int?
    let expectedPixelHeight: Int?
    let maximumBytes: Int
    let maximumSourceEdge: Int
    let maximumSourcePixels: Int
    let maximumPreviewEdge: Int
    let maximumPreviewPixels: Int?
}

/// A `CGImage` is immutable after creation, so it can safely cross the
/// non-main decoding boundary without exposing mutable ImageIO state to the
/// main actor.
private struct DecodedFloorPlanPreview: @unchecked Sendable {
    let image: CGImage
}

/// Keeps all bounded ImageIO metadata inspection and thumbnail creation off
/// the main actor. A renderer creates one short-lived decoder per preview, so
/// separate previews do not serialize behind shared mutable ImageIO state.
private actor BoundedFloorPlanPreviewDecoder {
    func decode(_ input: BoundedFloorPlanPreviewDecodingInput) throws -> DecodedFloorPlanPreview {
        let maximumPreviewEdge = input.maximumPreviewEdge
        guard input.jpegData.count == input.expectedByteCount,
            input.jpegData.count <= input.maximumBytes,
            let source = CGImageSourceCreateWithData(input.jpegData as CFData, nil),
            CGImageSourceGetCount(source) == 1,
            let sourceType = CGImageSourceGetType(source),
            (sourceType as String) == UTType.jpeg.identifier,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            input.expectedPixelWidth.map({ width == $0 }) ?? true,
            input.expectedPixelHeight.map({ height == $0 }) ?? true
        else {
            throw ProductionFloorPlanPreviewRenderingError.invalidSanitizedJPEG
        }
        guard width > 0,
            height > 0,
            width <= input.maximumSourceEdge,
            height <= input.maximumSourceEdge,
            try checkedProduct(width, height) <= input.maximumSourcePixels
        else {
            throw ProductionFloorPlanPreviewRenderingError.previewBoundsExceeded
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPreviewEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ProductionFloorPlanPreviewRenderingError.previewBoundsExceeded
        }
        if let maximumPreviewPixels = input.maximumPreviewPixels {
            guard image.width > 0,
                image.height > 0,
                image.width <= maximumPreviewEdge,
                image.height <= maximumPreviewEdge,
                try checkedProduct(image.width, image.height) <= maximumPreviewPixels
            else {
                throw ProductionFloorPlanPreviewRenderingError.previewBoundsExceeded
            }
        }
        return DecodedFloorPlanPreview(image: image)
    }

    private func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw ProductionFloorPlanPreviewRenderingError.previewBoundsExceeded }
        return result
    }
}

/// Displays only protected bytes that were admitted with a verified
/// floor-plan binding record. The mirror projection supplies the immutable
/// metadata, and the same live read authorization is checked around storage
/// and decode awaits.
@MainActor
struct ProductionBoundFloorPlanPreviewRenderer: BoundFloorPlanPreviewRendering {
    private static let maximumBytes = 32 * 1_024 * 1_024
    private static let maximumSourceEdge = 8_192
    private static let maximumSourcePixels = 64_000_000
    private static let maximumPreviewEdge = 2_048
    private let persistence: SwiftDataPersistenceStore
    private let account: AccountContext
    private let currentContext: any CurrentAuthorizationContextProviding

    init(persistence: SwiftDataPersistenceStore, account: AccountContext, currentContext: any CurrentAuthorizationContextProviding) {
        self.persistence = persistence
        self.account = account
        self.currentContext = currentContext
    }

    func renderBoundFloorPlan(_ asset: FloorPlanAssetReadProjection, authorization: AuthorizedOperationContext) async throws -> FloorPlanPreview {
        guard authorization.action == .readAttachment,
            authorization.account == account,
            asset.assetID == asset.metadata.id,
            asset.metadata.fieldName == "floorPlanAsset",
            asset.metadata.contentType == "image/jpeg",
            (1...Self.maximumBytes).contains(asset.metadata.byteCount),
            await currentContext.validateCurrent(authorization)
        else {
            throw ProductionFloorPlanPreviewRenderingError.unauthorized
        }
        let bytes = try await persistence.data(for: asset.assetID, namespace: account.namespace)
        guard bytes.count == asset.metadata.byteCount,
            CloudRecordAssetDescriptor.sha256(for: bytes) == asset.metadata.sha256,
            await currentContext.validateCurrent(authorization)
        else {
            throw ProductionFloorPlanPreviewRenderingError.invalidDescriptor
        }
        try Task.checkCancellation()
        let decodingInput = BoundedFloorPlanPreviewDecodingInput(
            jpegData: bytes, expectedByteCount: asset.metadata.byteCount, expectedPixelWidth: nil, expectedPixelHeight: nil,
            maximumBytes: Self.maximumBytes, maximumSourceEdge: Self.maximumSourceEdge, maximumSourcePixels: Self.maximumSourcePixels,
            maximumPreviewEdge: Self.maximumPreviewEdge, maximumPreviewPixels: nil
        )
        let decodedPreview: DecodedFloorPlanPreview
        do {
            let decoder = BoundedFloorPlanPreviewDecoder()
            decodedPreview = try await decoder.decode(decodingInput)
        } catch {
            // This legacy entry point treats every ImageIO validation failure
            // as an invalid bound asset rather than exposing bound details.
            throw ProductionFloorPlanPreviewRenderingError.invalidSanitizedJPEG
        }
        guard await currentContext.validateCurrent(authorization) else {
            throw ProductionFloorPlanPreviewRenderingError.invalidSanitizedJPEG
        }
        return FloorPlanPreview(
            image: decodedPreview.image, accessibilityDescription: "Verified floor plan from the active workspace. Use the Anchor list for a text alternative."
        )
    }
}

/// Reads only a claimed sanitized lease and never receives a source URL or raw
/// importer bytes. Every successfully claimed lease is released because a
/// preview is non-authoritative and must not consume the staged attachment.
@MainActor
struct ProductionFloorPlanPreviewRenderer: FloorPlanPreviewRendering {
    private static let maximumSanitizedJPEGBytes = 32 * 1_024 * 1_024
    private static let maximumSourceEdge = 8_192
    private static let maximumSourcePixels = 64_000_000
    private static let maximumPreviewEdge = 2_048
    private static let maximumPreviewPixels = maximumPreviewEdge * maximumPreviewEdge

    private let staging: any PrivateAttachmentStaging
    private let currentContext: any CurrentAuthorizationContextProviding

    init(staging: any PrivateAttachmentStaging, currentContext: any CurrentAuthorizationContextProviding) {
        self.staging = staging
        self.currentContext = currentContext
    }

    func renderFloorPlan(_ descriptor: SanitizedContentDescriptor, authorization: AuthorizedOperationContext) async throws -> FloorPlanPreview {
        try validateDescriptor(descriptor)
        try await validateAuthorization(authorization, for: descriptor)
        try Task.checkCancellation()

        let claim = try await staging.claim(descriptor.stagingToken, namespace: descriptor.namespace)
        do {
            try Task.checkCancellation()
            try validate(claim, against: descriptor)
            try await validateAuthorization(authorization, for: descriptor)

            let decodingInput = BoundedFloorPlanPreviewDecodingInput(
                jpegData: claim.sanitizedBytes, expectedByteCount: descriptor.byteCount, expectedPixelWidth: descriptor.pixelWidth,
                expectedPixelHeight: descriptor.pixelHeight, maximumBytes: Self.maximumSanitizedJPEGBytes,
                maximumSourceEdge: Self.maximumSourceEdge, maximumSourcePixels: Self.maximumSourcePixels,
                maximumPreviewEdge: Self.maximumPreviewEdge, maximumPreviewPixels: Self.maximumPreviewPixels
            )
            let decoder = BoundedFloorPlanPreviewDecoder()
            let decodedPreview = try await decoder.decode(decodingInput)
            try Task.checkCancellation()
            try await validateAuthorization(authorization, for: descriptor)

            await staging.release(claim)
            return FloorPlanPreview(image: decodedPreview.image)
        } catch {
            await staging.release(claim)
            throw error
        }
    }

    private func validateAuthorization(_ authorization: AuthorizedOperationContext, for descriptor: SanitizedContentDescriptor) async throws {
        guard authorization.action == .readAttachment,
            AttachmentNamespace(account: authorization.account) == descriptor.namespace,
            await currentContext.validateCurrent(authorization)
        else {
            throw ProductionFloorPlanPreviewRenderingError.unauthorized
        }
    }

    private func validateDescriptor(_ descriptor: SanitizedContentDescriptor) throws {
        guard descriptor.purpose == .floorPlan,
            descriptor.contentType == .jpeg,
            descriptor.byteCount > 0,
            descriptor.byteCount <= Self.maximumSanitizedJPEGBytes,
            descriptor.pixelWidth > 0,
            descriptor.pixelHeight > 0,
            descriptor.pixelWidth <= Self.maximumSourceEdge,
            descriptor.pixelHeight <= Self.maximumSourceEdge,
            try Self.checkedProduct(descriptor.pixelWidth, descriptor.pixelHeight) <= Self.maximumSourcePixels,
            !descriptor.domainSeparatedSHA256.isEmpty
        else {
            throw ProductionFloorPlanPreviewRenderingError.invalidDescriptor
        }
    }

    private func validate(_ claim: ClaimedStagedAttachment, against descriptor: SanitizedContentDescriptor) throws {
        guard claim.token == descriptor.stagingToken,
            claim.attachmentID == descriptor.id,
            claim.metadata.attachmentID == descriptor.id,
            claim.namespace == descriptor.namespace,
            claim.expiresAt == descriptor.stagingExpiresAt,
            claim.metadata.purpose == .floorPlan,
            claim.metadata.contentType == .jpeg,
            claim.metadata.byteCount == descriptor.byteCount,
            claim.sanitizedBytes.count == descriptor.byteCount,
            claim.metadata.contentSHA256 == descriptor.contentSHA256,
            CloudRecordAssetDescriptor.sha256(for: claim.sanitizedBytes) == descriptor.contentSHA256,
            claim.metadata.domainSeparatedSHA256 == descriptor.domainSeparatedSHA256,
            ContentSafetyService.digest(for: claim.sanitizedBytes, purpose: .floorPlan) == descriptor.domainSeparatedSHA256
        else {
            throw ProductionFloorPlanPreviewRenderingError.stagingMismatch
        }
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (result, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw ProductionFloorPlanPreviewRenderingError.previewBoundsExceeded }
        return result
    }
}
