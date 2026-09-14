import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public struct SanitizedContentDescriptor: Codable, Hashable, Sendable {
    public let id: ObjectID
    public let stagingToken: AttachmentStagingToken
    public let stagingExpiresAt: Date
    public let namespace: AttachmentNamespace
    public let purpose: ContentPurpose
    public let contentType: ContentType
    public let byteCount: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let contentSHA256: String
    public let domainSeparatedSHA256: String

    public init(
        id: ObjectID, stagingToken: AttachmentStagingToken, stagingExpiresAt: Date,
        namespace: AttachmentNamespace, purpose: ContentPurpose, contentType: ContentType, byteCount: Int,
        pixelWidth: Int, pixelHeight: Int, contentSHA256: String, domainSeparatedSHA256: String
    ) {
        self.id = id
        self.stagingToken = stagingToken
        self.stagingExpiresAt = stagingExpiresAt
        self.namespace = namespace
        self.purpose = purpose
        self.contentType = contentType
        self.byteCount = byteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.contentSHA256 = contentSHA256
        self.domainSeparatedSHA256 = domainSeparatedSHA256
    }
}

public struct ContentSafetyService: Sendable {
    public static let maximumRawImageBytes = 32 * 1_024 * 1_024
    public static let maximumRawPDFBytes = 64 * 1_024 * 1_024
    public static let maximumInputEdge = 16_384
    public static let maximumInputPixels = 64_000_000
    public static let maximumDecodedBytes = 256 * 1_024 * 1_024
    public static let maximumPDFPages = 100
    public static let maximumPDFBoxPoints = 14_400

    private let decoder: any ContentSanitizingDecoder
    private let staging: any PrivateAttachmentStaging
    private let currentContext: any CurrentAuthorizationContextProviding

    public init(
        decoder: any ContentSanitizingDecoder, staging: any PrivateAttachmentStaging,
        currentContext: any CurrentAuthorizationContextProviding
    ) {
        self.decoder = decoder
        self.staging = staging
        self.currentContext = currentContext
    }

    public func sanitizeAndStage(
        source: some OpaqueContentSource, purpose: ContentPurpose,
        selectedPDFPage: Int? = nil, authorization: AuthorizedOperationContext
    ) async throws -> SanitizedContentDescriptor {
        var state = ContentSafetyProcessingState.initialized
        try await validateAuthorization(authorization)
        state = try ContentSafetyStateMachine.transition(from: state, to: .authorized)

        let validatedSource = try readAndInspect(source, purpose: purpose)
        state = try ContentSafetyStateMachine.transition(from: state, to: .sourced)
        try validate(
            type: validatedSource.signatureType, metadata: validatedSource.metadata,
            purpose: purpose)
        state = try ContentSafetyStateMachine.transition(from: state, to: .validated)

        let outputLimits = limits(for: purpose)
        let result = try decoder.decodeAndSanitize(
            validatedSource.bytes,
            sourceType: validatedSource.signatureType, purpose: purpose, selectedPDFPage: selectedPDFPage,
            outputEdgeLimit: outputLimits.edge, outputByteLimit: outputLimits.bytes)
        try validate(
            decoded: result.decoded, signatureType: validatedSource.signatureType, purpose: purpose,
            selectedPDFPage: selectedPDFPage)
        state = try ContentSafetyStateMachine.transition(from: state, to: .decoded)
        try validate(raster: result.raster, limits: outputLimits)
        state = try ContentSafetyStateMachine.transition(from: state, to: .sanitized)

        let descriptor = try await stage(result.raster, purpose: purpose, authorization: authorization)
        state = try ContentSafetyStateMachine.transition(from: state, to: .staged)
        _ = state
        return descriptor
    }

    private func readAndInspect(
        _ source: some OpaqueContentSource, purpose: ContentPurpose
    ) throws -> ValidatedContentSource {
        let metadata = try source.metadata()
        try validateDeclaredMetadata(metadata, purpose: purpose)
        let rawLimit = metadata.declaredType == .pdf ? Self.maximumRawPDFBytes : Self.maximumRawImageBytes
        var reader = try source.makeReader()
        var bytes = Data()
        while let chunk = try reader.nextChunk(maximumBytes: 64 * 1_024) {
            guard !chunk.isEmpty, chunk.count <= 64 * 1_024, bytes.count <= rawLimit - chunk.count else {
                throw ContentSafetyError.sourceSizeExceeded
            }
            bytes.append(chunk)
        }
        guard bytes.count == metadata.byteCount else {
            throw ContentSafetyError.invalidSourceMetadata
        }
        return ValidatedContentSource(
            metadata: metadata, bytes: bytes,
            signatureType: try ContentSignature.detect(in: bytes))
    }

    private func stage(
        _ raster: SanitizedRaster, purpose: ContentPurpose,
        authorization: AuthorizedOperationContext
    ) async throws -> SanitizedContentDescriptor {
        try await validateAuthorization(authorization)
        let namespace = AttachmentNamespace(account: authorization.account)
        let digest = Self.digest(for: raster.bytes, purpose: purpose)
        let metadata = SanitizedAttachmentStagingMetadata(
            purpose: purpose, contentType: raster.outputType,
            byteCount: raster.bytes.count,
            contentSHA256: SHA256.hash(data: raster.bytes).map { String(format: "%02x", $0) }.joined(),
            domainSeparatedSHA256: digest)
        let lease = try await staging.stage(raster.bytes, metadata: metadata, namespace: namespace)
        do {
            try await validateAuthorization(authorization)
        } catch {
            try? await staging.remove(lease.token, namespace: namespace)
            throw error
        }
        return SanitizedContentDescriptor(
            id: lease.attachmentID, stagingToken: lease.token,
            stagingExpiresAt: lease.expiresAt, namespace: namespace, purpose: purpose,
            contentType: raster.outputType, byteCount: raster.bytes.count, pixelWidth: raster.width,
            pixelHeight: raster.height, contentSHA256: metadata.contentSHA256, domainSeparatedSHA256: digest)
    }

    public func cleanup(
        _ descriptor: SanitizedContentDescriptor, authorization: AuthorizedOperationContext
    ) async throws {
        try await validateAuthorization(authorization)
        guard descriptor.namespace == AttachmentNamespace(account: authorization.account) else {
            throw ContentSafetyError.unauthorized
        }
        _ = try ContentSafetyStateMachine.transition(from: .staged, to: .cleanedUp)
        try await staging.remove(descriptor.stagingToken, namespace: descriptor.namespace)
    }

    public static func digest(for bytes: Data, purpose: ContentPurpose) -> String {
        let domain = Data("netzwerkdoku.content-safety.sanitized.v1\\0\(purpose.rawValue)\\0".utf8)
        return SHA256.hash(data: domain + bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func validateAuthorization(_ authorization: AuthorizedOperationContext) async throws {
        guard authorization.action == .createAttachment else { throw ContentSafetyError.invalidOperationAction }
        guard await currentContext.validateCurrent(authorization) else {
            throw ContentSafetyError.unauthorized
        }
    }

    private func validate(type signatureType: ContentType, metadata: UntrustedContentMetadata, purpose: ContentPurpose) throws {
        guard metadata.declaredType == signatureType else { throw ContentSafetyError.typeMismatch }
        guard signatureType != .pdf || purpose == .floorPlan else { throw ContentSafetyError.purposeTypeMismatch }
    }

    private func validateDeclaredMetadata(_ metadata: UntrustedContentMetadata, purpose: ContentPurpose) throws {
        let rawLimit = metadata.declaredType == .pdf ? Self.maximumRawPDFBytes : Self.maximumRawImageBytes
        guard metadata.byteCount >= 0, metadata.byteCount <= rawLimit else { throw ContentSafetyError.sourceSizeExceeded }
        guard metadata.declaredType != .pdf || purpose == .floorPlan else { throw ContentSafetyError.purposeTypeMismatch }
    }

    private func validate(
        decoded: DecodedContent, signatureType: ContentType, purpose: ContentPurpose,
        selectedPDFPage: Int?
    ) throws {
        guard decoded.sourceType == signatureType else { throw ContentSafetyError.typeMismatch }
        guard !decoded.isAnimated else { throw ContentSafetyError.animatedContent }
        try validateDimensions(decoded)
        if decoded.sourceType == .pdf {
            try validatePDF(decoded, purpose: purpose, selectedPage: selectedPDFPage)
        }
    }

    private func validateDimensions(_ decoded: DecodedContent) throws {
        guard decoded.width > 0, decoded.height > 0,
            decoded.width <= Self.maximumInputEdge, decoded.height <= Self.maximumInputEdge
        else {
            throw ContentSafetyError.invalidDimensions
        }
        let pixelCount = try Self.checkedProduct(decoded.width, decoded.height)
        guard pixelCount <= Self.maximumInputPixels,
            try Self.checkedProduct(pixelCount, 4) <= Self.maximumDecodedBytes
        else {
            throw ContentSafetyError.decodedSizeExceeded
        }
    }

    private func validatePDF(
        _ decoded: DecodedContent, purpose: ContentPurpose, selectedPage: Int?
    ) throws {
        guard purpose == .floorPlan else { throw ContentSafetyError.purposeTypeMismatch }
        guard decoded.pageCount > 0, decoded.pageCount <= Self.maximumPDFPages else {
            throw ContentSafetyError.pageCountExceeded
        }
        guard decoded.pageBoxesAreFiniteAndBounded else {
            throw ContentSafetyError.invalidPDFPageBoxes
        }
        guard let selectedPage else { throw ContentSafetyError.missingSelectedPDFPage }
        guard (0..<decoded.pageCount).contains(selectedPage) else {
            throw ContentSafetyError.invalidSelectedPDFPage
        }
    }

    private func validate(raster: SanitizedRaster, limits: (edge: Int, pixels: Int, bytes: Int)) throws {
        guard raster.outputType == .jpeg else { throw ContentSafetyError.outputTypeMismatch }
        guard raster.width > 0, raster.height > 0, raster.width <= limits.edge, raster.height <= limits.edge,
            try Self.checkedProduct(raster.width, raster.height) <= limits.pixels
        else {
            throw ContentSafetyError.outputDimensionsExceeded
        }
        guard raster.bytes.count <= limits.bytes else { throw ContentSafetyError.outputSizeExceeded }
    }

    private func limits(for purpose: ContentPurpose) -> (edge: Int, pixels: Int, bytes: Int) {
        switch purpose {
        case .evidence: (4_096, 4_096 * 4_096, 12 * 1_024 * 1_024)
        case .floorPlan: (8_192, 64_000_000, 32 * 1_024 * 1_024)
        }
    }

    private static func checkedProduct(_ lhs: Int, _ rhs: Int) throws -> Int {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        guard !overflow else { throw ContentSafetyError.decodedSizeExceeded }
        return value
    }
}

private struct ValidatedContentSource {
    let metadata: UntrustedContentMetadata
    let bytes: Data
    let signatureType: ContentType
}

enum ContentSignature {
    static func detect(in bytes: Data) throws -> ContentType {
        let prefix = [UInt8](bytes.prefix(16))
        guard !prefix.isEmpty else { throw ContentSafetyError.unsupportedSignature }
        if prefix.starts(with: [0xFF, 0xD8, 0xFF]) { return .jpeg }
        if prefix.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
        if prefix.starts(with: [0x25, 0x50, 0x44, 0x46, 0x2D]) { return .pdf }
        guard prefix.count >= 12, String(bytes: prefix[4..<8], encoding: .ascii) == "ftyp",
            let brand = String(bytes: prefix[8..<12], encoding: .ascii)
        else {
            throw ContentSafetyError.unsupportedSignature
        }
        switch brand {
        case "heic", "heix": return .heic
        case "heif", "mif1", "msf1", "hevc", "hevx": return .heif
        default: throw ContentSafetyError.unsupportedSignature
        }
    }
}
