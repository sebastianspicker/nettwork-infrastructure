import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// The only attachment intents accepted by the content-safety boundary.
public enum ContentPurpose: String, Codable, Hashable, Sendable {
    case evidence
    case floorPlan
}
/// An allowlisted type. Values are deliberately not arbitrary MIME strings.
public enum ContentType: String, Codable, Hashable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
    case heic = "image/heic"
    case heif = "image/heif"
    case pdf = "application/pdf"

    public var isImage: Bool { self != .pdf }
}

public struct UntrustedContentMetadata: Hashable, Sendable {
    public let byteCount: Int
    public let declaredType: ContentType

    public init(byteCount: Int, declaredType: ContentType) {
        self.byteCount = byteCount
        self.declaredType = declaredType
    }
}

/// A source is intentionally opaque: feature code cannot pass arbitrary file URLs into the domain service.
public protocol OpaqueContentSource: Sendable {
    var sourceID: String { get }
    func metadata() throws -> UntrustedContentMetadata
    func makeReader() throws -> any OpaqueContentByteReader
}

/// Trusted platform adapters stream from an already-open regular file or photo
/// capability and must honor the requested chunk bound.
public protocol OpaqueContentByteReader: Sendable {
    mutating func nextChunk(maximumBytes: Int) throws -> Data?
}

/// A staging token is opaque to the caller and must never be interpreted as a filesystem path.
public struct AttachmentStagingToken: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

/// The staging implementation sets a bounded lifetime; callers retain only this opaque lease.
public struct StagedAttachmentLease: Codable, Hashable, Sendable {
    public let token: AttachmentStagingToken
    /// The staging registry, not the caller's descriptor, assigns this identity.
    public let attachmentID: ObjectID
    public let expiresAt: Date

    public init(token: AttachmentStagingToken, attachmentID: ObjectID, expiresAt: Date) {
        self.token = token
        self.attachmentID = attachmentID
        self.expiresAt = expiresAt
    }
}

/// Registry-owned facts recorded together with freshly sanitized bytes. They
/// prevent a later descriptor from changing the attachment purpose or type.
public struct SanitizedAttachmentStagingMetadata: Hashable, Sendable {
    /// Immutable identity assigned by the private staging registry.
    public let attachmentID: ObjectID
    public let purpose: ContentPurpose
    public let contentType: ContentType
    public let byteCount: Int
    public let contentSHA256: String
    public let domainSeparatedSHA256: String

    public init(
        purpose: ContentPurpose, contentType: ContentType, byteCount: Int, contentSHA256: String,
        domainSeparatedSHA256: String
    ) {
        attachmentID = ObjectID()
        self.purpose = purpose
        self.contentType = contentType
        self.byteCount = byteCount
        self.contentSHA256 = contentSHA256
        self.domainSeparatedSHA256 = domainSeparatedSHA256
    }

    /// Only staging implementations may replace the provisional identity with
    /// the registry-owned identity stored with the private bytes.
    func assigningRegistryAttachmentID(_ attachmentID: ObjectID) -> Self {
        Self(
            attachmentID: attachmentID, purpose: purpose, contentType: contentType, byteCount: byteCount,
            contentSHA256: contentSHA256, domainSeparatedSHA256: domainSeparatedSHA256)
    }

    private init(
        attachmentID: ObjectID, purpose: ContentPurpose, contentType: ContentType, byteCount: Int,
        contentSHA256: String, domainSeparatedSHA256: String
    ) {
        self.attachmentID = attachmentID
        self.purpose = purpose
        self.contentType = contentType
        self.byteCount = byteCount
        self.contentSHA256 = contentSHA256
        self.domainSeparatedSHA256 = domainSeparatedSHA256
    }
}

/// An opaque, single-consumer claim over a private staging lease. The bytes are
/// copied from the staging registry before they cross into an authority; no
/// filesystem location is exposed to the caller.
public struct ClaimedStagedAttachment: Sendable {
    public let sanitizedBytes: Data
    public let metadata: SanitizedAttachmentStagingMetadata
    public let attachmentID: ObjectID
    public let token: AttachmentStagingToken
    public let namespace: AttachmentNamespace
    public let expiresAt: Date
    let claimID: UUID

    init(
        sanitizedBytes: Data, metadata: SanitizedAttachmentStagingMetadata, attachmentID: ObjectID,
        token: AttachmentStagingToken, namespace: AttachmentNamespace, expiresAt: Date, claimID: UUID
    ) {
        self.sanitizedBytes = sanitizedBytes
        self.metadata = metadata
        self.attachmentID = attachmentID
        self.token = token
        self.namespace = namespace
        self.expiresAt = expiresAt
        self.claimID = claimID
    }
}

public struct AttachmentNamespace: Codable, Hashable, Sendable {
    public let containerIdentifier: String
    public let accountRecordName: String
    public let workspaceID: ObjectID
    public let zoneName: String
    public let zoneOwnerRecordName: String
    public let sessionGeneration: UInt64

    public init(account: AccountContext) {
        containerIdentifier = account.namespace.containerIdentifier
        accountRecordName = account.namespace.cloudKitAccountRecordName
        workspaceID = account.namespace.workspaceID
        zoneName = account.namespace.zoneName
        zoneOwnerRecordName = account.namespace.zoneOwnerRecordName
        sessionGeneration = account.namespace.sessionGeneration
    }
}

/// Implementations own private, short-lived file staging and all associated cleanup.
public protocol PrivateAttachmentStaging: Sendable {
    func stage(
        _ sanitizedBytes: Data, metadata: SanitizedAttachmentStagingMetadata,
        namespace: AttachmentNamespace
    ) async throws -> StagedAttachmentLease
    /// Atomically marks a lease as in use and returns a value copy of its bytes.
    /// The caller must either complete or release the returned claim.
    func claim(_ token: AttachmentStagingToken, namespace: AttachmentNamespace) async throws -> ClaimedStagedAttachment
    /// Removes the staged bytes only after the downstream authority committed.
    func complete(_ claim: ClaimedStagedAttachment) async throws
    /// Makes an uncommitted claim available again after a failed bind attempt.
    func release(_ claim: ClaimedStagedAttachment) async
    func remove(_ token: AttachmentStagingToken, namespace: AttachmentNamespace) async throws
}

public extension PrivateAttachmentStaging {
    /// An authoritative receipt is terminal success. Cleanup failure must not
    /// turn that success into a retry of the already-committed mutation. The
    /// fallback releases the claim and attempts an idempotent token removal;
    /// an implementation may retain the unclaimed lease for its normal expiry
    /// purge if protected storage is temporarily unavailable.
    func finalizeCommitted(_ claim: ClaimedStagedAttachment) async {
        do {
            try await complete(claim)
        } catch {
            await release(claim)
            try? await remove(claim.token, namespace: claim.namespace)
        }
    }
}

/// Revalidates a claimed operation against live account and session state at
/// each authority boundary. This is asynchronous so actor-backed providers can
/// observe invalidation that occurs while a caller is suspended.
public protocol CurrentAuthorizationContextProviding: Sendable {
    func validateCurrent(_ context: AuthorizedOperationContext) async -> Bool
}

public struct DecodedContent: Hashable, Sendable {
    public let sourceType: ContentType
    public let width: Int
    public let height: Int
    public let pageCount: Int
    public let isAnimated: Bool
    public let pageBoxesAreFiniteAndBounded: Bool

    public init(
        sourceType: ContentType, width: Int, height: Int, pageCount: Int = 0,
        isAnimated: Bool = false, pageBoxesAreFiniteAndBounded: Bool = true
    ) {
        self.sourceType = sourceType
        self.width = width
        self.height = height
        self.pageCount = pageCount
        self.isAnimated = isAnimated
        self.pageBoxesAreFiniteAndBounded = pageBoxesAreFiniteAndBounded
    }
}

public struct SanitizedRaster: Hashable, Sendable {
    public let bytes: Data
    public let outputType: ContentType
    public let width: Int
    public let height: Int

    public init(bytes: Data, outputType: ContentType = .jpeg, width: Int, height: Int) {
        self.bytes = bytes
        self.outputType = outputType
        self.width = width
        self.height = height
    }
}

/// The platform boundary performs an actual decode and returns freshly encoded metadata-free raster bytes.
public protocol ContentSanitizingDecoder: Sendable {
    func decodeAndSanitize(
        _ bytes: Data, sourceType: ContentType, purpose: ContentPurpose,
        selectedPDFPage: Int?, outputEdgeLimit: Int, outputByteLimit: Int
    ) throws -> (decoded: DecodedContent, raster: SanitizedRaster)
}

public enum ContentSafetyError: Error, Equatable, Sendable {
    case unauthorized
    case invalidOperationAction
    case sourceSizeExceeded
    case invalidSourceMetadata
    case unsupportedSignature
    case typeMismatch
    case purposeTypeMismatch
    case animatedContent
    case invalidDimensions
    case decodedSizeExceeded
    case pageCountExceeded
    case invalidPDFPageBoxes
    case missingSelectedPDFPage
    case invalidSelectedPDFPage
    case outputTypeMismatch
    case outputDimensionsExceeded
    case outputSizeExceeded
    case invalidStateTransition
    case decoderUnavailable
    case decodeFailed
}

public enum ContentSafetyProcessingState: Hashable, Sendable {
    case initialized
    case authorized
    case sourced
    case validated
    case decoded
    case sanitized
    case staged
    case cleanedUp
}

public enum ContentSafetyStateMachine {
    public static func transition(
        from state: ContentSafetyProcessingState,
        to nextState: ContentSafetyProcessingState
    ) throws -> ContentSafetyProcessingState {
        let permitted =
            switch (state, nextState) {
            case (.initialized, .authorized), (.authorized, .sourced), (.sourced, .validated),
                (.validated, .decoded), (.decoded, .sanitized), (.sanitized, .staged), (.staged, .cleanedUp):
                true
            default: false
            }
        guard permitted else { throw ContentSafetyError.invalidStateTransition }
        return nextState
    }
}
