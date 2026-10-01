import ContentSafety
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

enum ProductionAttachmentEvidenceFeatureServiceError: LocalizedError {
    case invalidDescriptor
    case namespaceMismatch
    case evidenceMismatch
    case receiptMismatch

    var errorDescription: String? {
        switch self {
        case .invalidDescriptor: "The staged evidence descriptor is invalid."
        case .namespaceMismatch: "The evidence is outside the active account workspace."
        case .evidenceMismatch: "The authoritative binding did not confirm the prepared evidence hash."
        case .receiptMismatch: "The authoritative binding did not return its expected receipt."
        }
    }
}

/// App adapter for the evidence intake flow. Content safety and the binding
/// service retain all byte access, staging claims, session validation, and
/// authoritative mutation work.
@MainActor
public struct ProductionAttachmentEvidenceFeatureService: AttachmentEvidenceFeatureService {
    private let account: AccountContext
    private let contentSafety: ContentSafetyService
    private let bindingService: AuthorizedAttachmentEvidenceBindingService
    private let operationBoundary: ProductionOperationBoundary

    public init(
        account: AccountContext, contentSafety: ContentSafetyService, bindingService: AuthorizedAttachmentEvidenceBindingService,
        operationBoundary: ProductionOperationBoundary
    ) {
        self.account = account
        self.contentSafety = contentSafety
        self.bindingService = bindingService
        self.operationBoundary = operationBoundary
    }

    public func prepareEvidence(source: any OpaqueContentSource, authorization: AuthorizedOperationContext) async throws -> PreparedWorkOrderEvidence {
        try await operationBoundary.perform(.assetTransfer) {
            try await self.performPrepareEvidence(source: source, authorization: authorization)
        }
    }

    private func performPrepareEvidence(source: any OpaqueContentSource, authorization: AuthorizedOperationContext) async throws -> PreparedWorkOrderEvidence {
        try validate(authorization: authorization)
        let descriptor = try await contentSafety.sanitizeAndStage(source: source, purpose: .evidence, authorization: authorization)
        do {
            return try PreparedWorkOrderEvidence(
                descriptor: descriptor,
                evidence: evidenceHash(from: descriptor)
            )
        } catch {
            try? await contentSafety.cleanup(descriptor, authorization: authorization)
            throw error
        }
    }

    public func bindPreparedEvidence(
        _ prepared: PreparedWorkOrderEvidence, to workOrderID: ObjectID, authorization: AuthorizedOperationContext
    ) async throws -> AttachmentEvidenceBindingResult {
        try await operationBoundary.perform(.assetTransfer) {
            try await self.performBindPreparedEvidence(prepared, to: workOrderID, authorization: authorization)
        }
    }

    private func performBindPreparedEvidence(
        _ prepared: PreparedWorkOrderEvidence, to workOrderID: ObjectID, authorization: AuthorizedOperationContext
    ) async throws -> AttachmentEvidenceBindingResult {
        try validate(authorization: authorization)
        try validate(prepared)
        let intent = try AttachmentEvidenceBindingIntent(
            owner: AttachmentEvidenceOwner(workOrderID: workOrderID, namespace: authorization.account.namespace),
            attachmentID: prepared.evidence.id,
            evidence: prepared.evidence,
            authorization: authorization
        )
        let result = try await bindingService.reserveAndBind(descriptor: prepared.descriptor, workOrderID: workOrderID, authorization: authorization)
        guard result.evidence == prepared.evidence else {
            throw ProductionAttachmentEvidenceFeatureServiceError.evidenceMismatch
        }
        guard result.receipt == intent.expectedReceipt else {
            throw ProductionAttachmentEvidenceFeatureServiceError.receiptMismatch
        }
        return result
    }

    public func cleanupPreparedEvidence(_ prepared: PreparedWorkOrderEvidence, authorization: AuthorizedOperationContext) async throws {
        try await operationBoundary.perform(.assetTransfer) {
            try await self.performCleanupPreparedEvidence(prepared, authorization: authorization)
        }
    }

    private func performCleanupPreparedEvidence(_ prepared: PreparedWorkOrderEvidence, authorization: AuthorizedOperationContext) async throws {
        try validate(authorization: authorization)
        try validate(prepared)
        try await contentSafety.cleanup(prepared.descriptor, authorization: authorization)
    }

    private func validate(authorization: AuthorizedOperationContext) throws {
        guard authorization.action == .createAttachment else {
            throw AttachmentEvidenceBindingError.unauthorized
        }
        guard authorization.account == account else {
            throw ProductionAttachmentEvidenceFeatureServiceError.namespaceMismatch
        }
    }

    private func validate(_ prepared: PreparedWorkOrderEvidence) throws {
        let descriptor = prepared.descriptor
        let expectedEvidence = try evidenceHash(from: descriptor)
        guard descriptor.namespace == AttachmentNamespace(account: account),
            descriptor.purpose == .evidence,
            descriptor.contentType == .jpeg,
            descriptor.byteCount > 0,
            descriptor.id == prepared.evidence.id,
            prepared.evidence.contentType == descriptor.contentType.rawValue,
            prepared.evidence == expectedEvidence
        else {
            throw ProductionAttachmentEvidenceFeatureServiceError.invalidDescriptor
        }
    }

    private func evidenceHash(from descriptor: SanitizedContentDescriptor) throws -> EvidenceHash {
        guard descriptor.domainSeparatedSHA256.count == 64,
            let digest = Data(hexadecimalString: descriptor.domainSeparatedSHA256),
            digest.count == 32
        else {
            throw ProductionAttachmentEvidenceFeatureServiceError.invalidDescriptor
        }
        return EvidenceHash(
            id: descriptor.id,
            digest: try IntentDigest(algorithm: .sha256, bytes: Array(digest)),
            contentType: descriptor.contentType.rawValue
        )
    }
}

private extension Data {
    init?(hexadecimalString: String) {
        guard hexadecimalString.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexadecimalString.count / 2)
        var index = hexadecimalString.startIndex
        while index < hexadecimalString.endIndex {
            let next = hexadecimalString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexadecimalString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
