import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// The authoritative owner for attachment evidence. It intentionally carries
/// the complete attachment namespace rather than just a work-order identifier.
public struct AttachmentEvidenceOwner: Codable, Hashable, Sendable {
    public let workOrderID: ObjectID
    public let namespace: PersistenceNamespace

    public init(workOrderID: ObjectID, namespace: PersistenceNamespace) {
        self.workOrderID = workOrderID
        self.namespace = namespace
    }

    public func matches(_ attachmentNamespace: AttachmentNamespace) -> Bool {
        namespace.containerIdentifier == attachmentNamespace.containerIdentifier && namespace.cloudKitAccountRecordName == attachmentNamespace.accountRecordName
            && namespace.workspaceID == attachmentNamespace.workspaceID && namespace.zoneName == attachmentNamespace.zoneName
            && namespace.zoneOwnerRecordName == attachmentNamespace.zoneOwnerRecordName && namespace.sessionGeneration == attachmentNamespace.sessionGeneration
    }
}

/// A reservation is the only authority to consume one attachment slot and its
/// sanitized byte count. Its creation must be transactional with the owner
/// store's count and quota checks.
public struct AttachmentQuotaReservation: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public let owner: AttachmentEvidenceOwner
    public let attachmentID: ObjectID
    public let reservedCount: Int
    public let reservedBytes: Int
    public let expiresAt: Date

    public init(
        id: ObjectID = .init(), owner: AttachmentEvidenceOwner, attachmentID: ObjectID,
        reservedCount: Int, reservedBytes: Int, expiresAt: Date
    ) {
        self.id = id
        self.owner = owner
        self.attachmentID = attachmentID
        self.reservedCount = reservedCount
        self.reservedBytes = reservedBytes
        self.expiresAt = expiresAt
    }
}

/// The binding boundary receives this value-copy evidence rather than a file
/// capability or caller-supplied descriptor. Its fields were checked against
/// the registry-backed bytes immediately before reservation.
public struct VerifiedSanitizedAttachment: Sendable {
    public let attachmentID: ObjectID
    public let namespace: AttachmentNamespace
    public let purpose: ContentPurpose
    public let contentType: ContentType
    public let sanitizedBytes: Data
    public let byteCount: Int
    public let domainSeparatedSHA256: String

    init(
        attachmentID: ObjectID, namespace: AttachmentNamespace, purpose: ContentPurpose,
        contentType: ContentType, sanitizedBytes: Data, domainSeparatedSHA256: String
    ) {
        self.attachmentID = attachmentID
        self.namespace = namespace
        self.purpose = purpose
        self.contentType = contentType
        self.sanitizedBytes = sanitizedBytes
        byteCount = sanitizedBytes.count
        self.domainSeparatedSHA256 = domainSeparatedSHA256
    }
}

/// This boundary belongs to the authoritative work-order/attachment store. A
/// local staging file alone must never alter a work order, evidence list, or a
/// quota counter.
public protocol AttachmentEvidenceReservationAuthority: Sendable {
    func reserveAttachment(
        owner: AttachmentEvidenceOwner, attachment: VerifiedSanitizedAttachment
    ) async throws -> AttachmentQuotaReservation

    /// Performs the authoritative owner/evidence update using the reservation
    /// as a compare-and-swap precondition and returns the exact durable receipt
    /// for that committed operation.
    func bindReservedAttachment(
        _ reservation: AttachmentQuotaReservation,
        attachment: VerifiedSanitizedAttachment, intent: AttachmentEvidenceBindingIntent,
        authorization: AuthorizedOperationContext
    ) async throws -> OperationReceipt

    func releaseAttachmentReservation(_ reservation: AttachmentQuotaReservation) async
}

public enum AttachmentEvidenceBindingError: Error, Equatable, Sendable {
    case unauthorized
    case invalidOwner
    case expiredStagingLease
    case invalidReservation
    case bindingConflict
    case invalidReceipt
    case invalidAttachmentIdentity
    case invalidDigest
}

/// The exact, versioned intent for one authoritative attachment bind. The
/// expected receipt uses the domain's deterministic audit-event identity so a
/// retry cannot be acknowledged by a different committed mutation.
public struct AttachmentEvidenceBindingIntent: Hashable, Sendable {
    public let owner: AttachmentEvidenceOwner
    public let attachmentID: ObjectID
    public let evidence: EvidenceHash
    public let digest: IntentDigest
    public let expectedReceipt: OperationReceipt

    public init(
        owner: AttachmentEvidenceOwner, attachmentID: ObjectID, evidence: EvidenceHash,
        authorization: AuthorizedOperationContext
    ) throws {
        guard attachmentID == evidence.id else {
            throw AttachmentEvidenceBindingError.invalidAttachmentIdentity
        }
        self.owner = owner
        self.attachmentID = attachmentID
        self.evidence = evidence
        digest = try Self.digest(
            owner: owner, attachmentID: attachmentID, evidence: evidence,
            authorization: authorization)
        expectedReceipt = OperationReceipt(
            workspaceZone: authorization.account.namespace.workspaceZone,
            operationID: authorization.operationID, intentDigest: digest,
            auditEventID: AuditEvent.deterministicID(for: authorization.operationID))
    }

    private static func digest(
        owner: AttachmentEvidenceOwner, attachmentID: ObjectID,
        evidence: EvidenceHash, authorization: AuthorizedOperationContext
    ) throws -> IntentDigest {
        var material = Data("netzwerkdoku.attachment-evidence-binding.v1\0".utf8)
        append(owner.namespace.containerIdentifier, to: &material)
        append(owner.namespace.cloudKitAccountRecordName, to: &material)
        append(owner.namespace.workspaceID.description, to: &material)
        append(owner.namespace.zoneName, to: &material)
        append(owner.namespace.zoneOwnerRecordName, to: &material)
        append(String(owner.namespace.sessionGeneration), to: &material)
        append(owner.workOrderID.description, to: &material)
        append(authorization.operationID.description, to: &material)
        append(authorization.action.rawValue, to: &material)
        append(authorization.actor.cloudKitUserRecordName, to: &material)
        append(authorization.actor.role.rawValue, to: &material)
        append(authorization.actor.installationID, to: &material)
        append(String(authorization.actor.sessionGeneration), to: &material)
        append(String(authorization.capturedSessionGeneration), to: &material)
        append(attachmentID.description, to: &material)
        append(evidence.id.description, to: &material)
        append(evidence.digest.algorithm.rawValue, to: &material)
        append(Data(evidence.digest.bytes), to: &material)
        append(evidence.contentType, to: &material)
        return try IntentDigest(algorithm: .sha256, bytes: Array(SHA256.hash(data: material)))
    }

    private static func append(_ value: String, to material: inout Data) {
        append(Data(value.utf8), to: &material)
    }

    private static func append(_ value: Data, to material: inout Data) {
        var length = UInt64(value.count).bigEndian
        withUnsafeBytes(of: &length) { material.append(contentsOf: $0) }
        material.append(value)
    }
}

/// The evidence committed by the authority and its exact durable receipt.
public struct AttachmentEvidenceBindingResult: Hashable, Sendable {
    public let evidence: EvidenceHash
    public let receipt: OperationReceipt

    public init(evidence: EvidenceHash, receipt: OperationReceipt) {
        self.evidence = evidence
        self.receipt = receipt
    }
}

/// Binds a completed sanitized attachment to exactly one work-order owner only
/// after an injected authority atomically reserves count and byte quota. Cloud
/// and persistence commits remain outside this module by design.
public struct AuthorizedAttachmentEvidenceBindingService: Sendable {
    private let authority: any AttachmentEvidenceReservationAuthority
    private let staging: any PrivateAttachmentStaging
    private let currentContext: any CurrentAuthorizationContextProviding
    private let now: @Sendable () -> Date

    public init(
        authority: any AttachmentEvidenceReservationAuthority, staging: any PrivateAttachmentStaging,
        currentContext: any CurrentAuthorizationContextProviding,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.authority = authority
        self.staging = staging
        self.currentContext = currentContext
        self.now = now
    }

    public func reserveAndBind(
        descriptor: SanitizedContentDescriptor, workOrderID: ObjectID,
        authorization: AuthorizedOperationContext
    ) async throws -> AttachmentEvidenceBindingResult {
        try await validate(authorization: authorization, descriptor: descriptor)
        let owner = AttachmentEvidenceOwner(workOrderID: workOrderID, namespace: authorization.account.namespace)
        let claim = try await staging.claim(descriptor.stagingToken, namespace: descriptor.namespace)
        var reservation: AttachmentQuotaReservation?
        var committed = false
        do {
            try await validate(authorization: authorization, descriptor: descriptor)
            let attachment = try verifiedAttachment(from: claim, asserting: descriptor)
            let reserved = try await authority.reserveAttachment(owner: owner, attachment: attachment)
            reservation = reserved
            try await validate(authorization: authorization, descriptor: descriptor)
            guard reservationIsValid(reserved, owner: owner, attachment: attachment) else {
                throw AttachmentEvidenceBindingError.invalidReservation
            }

            let evidence = try evidenceHash(for: attachment)
            let intent = try AttachmentEvidenceBindingIntent(
                owner: owner,
                attachmentID: attachment.attachmentID, evidence: evidence, authorization: authorization)
            try await validate(authorization: authorization, descriptor: descriptor)
            let receipt = try await authority.bindReservedAttachment(
                reserved, attachment: attachment,
                intent: intent, authorization: authorization)
            guard receipt == intent.expectedReceipt else {
                throw AttachmentEvidenceBindingError.invalidReceipt
            }
            committed = true
            await staging.finalizeCommitted(claim)
            return AttachmentEvidenceBindingResult(evidence: evidence, receipt: receipt)
        } catch {
            await releaseUncommitted(reservation: reservation, claim: claim, committed: committed)
            throw error
        }
    }

    private func reservationIsValid(
        _ reservation: AttachmentQuotaReservation, owner: AttachmentEvidenceOwner,
        attachment: VerifiedSanitizedAttachment
    ) -> Bool {
        owner.matches(attachment.namespace) && reservation.owner == owner
            && reservation.attachmentID == attachment.attachmentID && reservation.reservedCount == 1
            && reservation.reservedBytes == attachment.byteCount && reservation.expiresAt > now()
    }

    private func releaseUncommitted(
        reservation: AttachmentQuotaReservation?, claim: ClaimedStagedAttachment, committed: Bool
    ) async {
        guard !committed else { return }
        if let reservation {
            await authority.releaseAttachmentReservation(reservation)
        }
        await staging.release(claim)
    }

    private func validate(
        authorization: AuthorizedOperationContext, descriptor: SanitizedContentDescriptor
    ) async throws {
        let namespace = AttachmentNamespace(account: authorization.account)
        guard authorization.action == .createAttachment else { throw AttachmentEvidenceBindingError.unauthorized }
        guard descriptor.namespace == namespace else { throw AttachmentEvidenceBindingError.invalidOwner }
        guard descriptor.stagingExpiresAt > now() else { throw AttachmentEvidenceBindingError.expiredStagingLease }
        guard await currentContext.validateCurrent(authorization) else {
            throw AttachmentEvidenceBindingError.unauthorized
        }
    }

    private func verifiedAttachment(
        from claim: ClaimedStagedAttachment,
        asserting descriptor: SanitizedContentDescriptor
    ) throws -> VerifiedSanitizedAttachment {
        guard claim.token == descriptor.stagingToken, claim.attachmentID == claim.metadata.attachmentID,
            descriptor.id == claim.attachmentID, claim.namespace == descriptor.namespace,
            claim.expiresAt == descriptor.stagingExpiresAt, claim.expiresAt > now(),
            claim.metadata.purpose == descriptor.purpose,
            claim.metadata.contentType == descriptor.contentType,
            claim.metadata.byteCount == descriptor.byteCount,
            claim.metadata.contentSHA256 == descriptor.contentSHA256,
            CloudRecordAssetDescriptor.sha256(for: claim.sanitizedBytes) == descriptor.contentSHA256,
            claim.metadata.domainSeparatedSHA256 == descriptor.domainSeparatedSHA256,
            claim.sanitizedBytes.count == claim.metadata.byteCount,
            try ContentSignature.detect(in: claim.sanitizedBytes) == claim.metadata.contentType,
            claim.metadata.contentType == .jpeg,
            ContentSafetyService.digest(for: claim.sanitizedBytes, purpose: claim.metadata.purpose) == claim.metadata.domainSeparatedSHA256
        else {
            throw AttachmentEvidenceBindingError.invalidDigest
        }
        return VerifiedSanitizedAttachment(
            attachmentID: claim.attachmentID, namespace: descriptor.namespace,
            purpose: descriptor.purpose, contentType: descriptor.contentType,
            sanitizedBytes: claim.sanitizedBytes, domainSeparatedSHA256: descriptor.domainSeparatedSHA256)
    }

    private func evidenceHash(for attachment: VerifiedSanitizedAttachment) throws -> EvidenceHash {
        guard let digest = Data(hexadecimalString: attachment.domainSeparatedSHA256), digest.count == 32 else {
            throw AttachmentEvidenceBindingError.invalidDigest
        }
        return try EvidenceHash(
            id: attachment.attachmentID,
            digest: IntentDigest(algorithm: .sha256, bytes: Array(digest)),
            contentType: attachment.contentType.rawValue)
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
