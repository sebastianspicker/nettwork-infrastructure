import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Organization-owned limits for one work order's sanitized evidence. The
/// application must inject a reviewed policy; this type deliberately has no
/// default quota values.
public struct AttachmentEvidenceQuotaPolicy: Codable, Hashable, Sendable {
    public let maximumAttachmentCount: Int
    public let maximumTotalBytes: Int
    public let reservationLifetime: TimeInterval

    public init(
        maximumAttachmentCount: Int, maximumTotalBytes: Int, reservationLifetime: TimeInterval
    ) throws {
        guard maximumAttachmentCount > 0, maximumTotalBytes > 0, reservationLifetime.isFinite,
            reservationLifetime > 0
        else {
            throw AttachmentEvidencePersistenceError.invalidQuotaPolicy
        }
        self.maximumAttachmentCount = maximumAttachmentCount
        self.maximumTotalBytes = maximumTotalBytes
        self.reservationLifetime = reservationLifetime
    }
}

/// The durable local compare-and-swap token for one attachment slot. It is
/// namespace scoped so account, workspace, zone, and session switches cannot
/// consume or release a different account's quota.
public struct AttachmentEvidenceReservationMetadata: Codable, Hashable, Sendable, Identifiable {
    public let id: ObjectID
    public let namespace: PersistenceNamespace
    public let workOrderID: ObjectID
    public let attachmentID: ObjectID
    public let reservedCount: Int
    public let reservedBytes: Int
    public let createdAt: Date
    public let expiresAt: Date

    public init(
        id: ObjectID = .init(), namespace: PersistenceNamespace, workOrderID: ObjectID,
        attachmentID: ObjectID, reservedCount: Int, reservedBytes: Int, createdAt: Date, expiresAt: Date
    ) throws {
        guard reservedCount == 1, reservedBytes > 0, createdAt < expiresAt else {
            throw AttachmentEvidencePersistenceError.invalidReservation
        }
        self.id = id
        self.namespace = namespace
        self.workOrderID = workOrderID
        self.attachmentID = attachmentID
        self.reservedCount = reservedCount
        self.reservedBytes = reservedBytes
        self.createdAt = createdAt
        self.expiresAt = expiresAt
    }
}

/// The facts established by the content-safety boundary. The byte digest is
/// deliberately retained with its purpose and output content type so a later
/// attachment lookup cannot mistake a generic file digest for evidence.
public struct SanitizedAttachmentProvenance: Codable, Hashable, Sendable {
    public let domainSeparatedSHA256: String
    public let purpose: String
    public let contentType: String
    public let byteCount: Int

    public init(
        domainSeparatedSHA256: String, purpose: String, contentType: String, byteCount: Int
    ) throws {
        let digest = domainSeparatedSHA256.lowercased()
        let normalizedPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedType = contentType.trimmingCharacters(in: .whitespacesAndNewlines)
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }), normalizedPurpose == "evidence",
            normalizedType == "image/jpeg", byteCount > 0
        else {
            throw AttachmentEvidencePersistenceError.invalidProvenance
        }
        self.domainSeparatedSHA256 = digest
        self.purpose = normalizedPurpose
        self.contentType = normalizedType
        self.byteCount = byteCount
    }
}

/// Immutable local evidence metadata written only after the authoritative
/// work-order/audit mutation returns its exact receipt.
public struct AttachmentEvidenceMetadata: Codable, Hashable, Sendable, Identifiable {
    public var id: ObjectID { attachmentID }
    public let namespace: PersistenceNamespace
    public let workOrderID: ObjectID
    public let attachmentID: ObjectID
    public let reservationID: ObjectID
    public let provenance: SanitizedAttachmentProvenance
    public let evidence: EvidenceHash
    public let receipt: OperationReceipt
    public let boundAt: Date

    public init(
        namespace: PersistenceNamespace, workOrderID: ObjectID, attachmentID: ObjectID,
        reservationID: ObjectID, provenance: SanitizedAttachmentProvenance, evidence: EvidenceHash,
        receipt: OperationReceipt, boundAt: Date
    ) throws {
        guard evidence.id == attachmentID, evidence.contentType == provenance.contentType,
            evidence.digest.algorithm == .sha256,
            evidence.digest.hexadecimalString == provenance.domainSeparatedSHA256,
            receipt.workspaceZone == namespace.workspaceZone
        else {
            throw AttachmentEvidencePersistenceError.invalidEvidenceBinding
        }
        self.namespace = namespace
        self.workOrderID = workOrderID
        self.attachmentID = attachmentID
        self.reservationID = reservationID
        self.provenance = provenance
        self.evidence = evidence
        self.receipt = receipt
        self.boundAt = boundAt
    }
}

public enum AttachmentEvidencePersistenceError: Error, Equatable, Sendable {
    case invalidQuotaPolicy
    case invalidReservation
    case invalidProvenance
    case invalidEvidenceBinding
    case reservationConflict(ObjectID)
    case reservationExpired(ObjectID)
    case quotaExceeded
    case attachmentAlreadyBound(ObjectID)
    case receiptMismatch(ObjectID)
}
