import CryptoKit
import Foundation
import NetworkModel

/// Authoritative, sanitized attachment facts. This record intentionally has
/// no source filename, location, EXIF, or staging capability.
public struct AttachmentEvidenceProvenanceRecord: Codable, Hashable, Sendable {
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
        guard digest.count == 64, digest.allSatisfy(\.isHexDigit), normalizedPurpose == "evidence",
            normalizedType == "image/jpeg", byteCount > 0
        else {
            throw AttachmentEvidenceActivationError.invalidProvenance
        }
        self.domainSeparatedSHA256 = digest
        self.purpose = normalizedPurpose
        self.contentType = normalizedType
        self.byteCount = byteCount
    }
}

/// A monotonically updated per-work-order quota ledger. The activation uses
/// the exact prior record as a precondition, so two devices cannot both spend
/// the final available slot or byte allocation.
public struct AttachmentEvidenceQuotaLedger: Codable, Hashable, Sendable {
    public let workOrderID: ObjectID
    public let attachmentCount: Int
    public let totalBytes: Int
    public let updatedAt: Date

    public init(workOrderID: ObjectID, attachmentCount: Int = 0, totalBytes: Int = 0, updatedAt: Date) throws {
        guard attachmentCount >= 0, totalBytes >= 0 else {
            throw AttachmentEvidenceActivationError.invalidQuotaLedger
        }
        self.workOrderID = workOrderID
        self.attachmentCount = attachmentCount
        self.totalBytes = totalBytes
        self.updatedAt = updatedAt
    }

    public func consuming(byteCount: Int, at date: Date) throws -> Self {
        guard byteCount > 0, attachmentCount < Int.max - 1, totalBytes <= Int.max - byteCount else {
            throw AttachmentEvidenceActivationError.invalidQuotaLedger
        }
        return try Self(
            workOrderID: workOrderID, attachmentCount: attachmentCount + 1,
            totalBytes: totalBytes + byteCount, updatedAt: date)
    }

    public var resourceKey: ResourceKey { .attachmentEvidenceQuotaLedger(for: workOrderID) }
}

/// The released reservation is retained as immutable audit-grade provenance,
/// rather than relying on a local delete to claim that quota was consumed.
public struct AttachmentEvidenceReservationRelease: Codable, Hashable, Sendable {
    public let id: ObjectID
    public let workOrderID: ObjectID
    public let attachmentID: ObjectID
    public let reservedCount: Int
    public let reservedBytes: Int
    public let expiresAt: Date
    public let releasedAt: Date
    public let operationID: ObjectID

    public init(
        id: ObjectID, workOrderID: ObjectID, attachmentID: ObjectID, reservedCount: Int,
        reservedBytes: Int, expiresAt: Date, releasedAt: Date, operationID: ObjectID
    ) throws {
        guard reservedCount == 1, reservedBytes > 0, releasedAt < expiresAt else {
            throw AttachmentEvidenceActivationError.invalidReservationRelease
        }
        self.id = id
        self.workOrderID = workOrderID
        self.attachmentID = attachmentID
        self.reservedCount = reservedCount
        self.reservedBytes = reservedBytes
        self.expiresAt = expiresAt
        self.releasedAt = releasedAt
        self.operationID = operationID
    }

    public var resourceKey: ResourceKey { .attachmentEvidenceReservationRelease(id) }
}

/// Immutable work-order, sanitized-byte, audit, and exact-receipt binding.
/// It is the only remotely authoritative relationship between attachment bytes
/// and a work order; the local file cache is never interpreted as evidence by
/// itself.
public struct AttachmentEvidenceBindingRecord: Codable, Hashable, Sendable {
    public let workOrderID: ObjectID
    public let attachmentID: ObjectID
    public let reservationID: ObjectID
    public let provenance: AttachmentEvidenceProvenanceRecord
    public let evidence: EvidenceHash
    /// The binding metadata and record-bound asset metadata are checked
    /// together before a CloudKit adapter is allowed to mirror its bytes.
    public let assetMetadata: CloudRecordAssetMetadata
    public let intentDigest: IntentDigest
    public let operationID: ObjectID
    public let auditEventID: ObjectID
    public let boundAt: Date

    public init(
        workOrderID: ObjectID, attachmentID: ObjectID, reservationID: ObjectID,
        provenance: AttachmentEvidenceProvenanceRecord, evidence: EvidenceHash,
        assetMetadata: CloudRecordAssetMetadata, intentDigest: IntentDigest, operationID: ObjectID,
        auditEventID: ObjectID, boundAt: Date
    ) throws {
        guard attachmentID == evidence.id, evidence.contentType == provenance.contentType,
            evidence.digest.algorithm == .sha256,
            evidence.digest.hexadecimalString == provenance.domainSeparatedSHA256,
            assetMetadata.id == attachmentID, assetMetadata.fieldName == "sanitizedAsset",
            assetMetadata.contentType == provenance.contentType,
            assetMetadata.byteCount == provenance.byteCount
        else {
            throw AttachmentEvidenceActivationError.invalidBinding
        }
        self.workOrderID = workOrderID
        self.attachmentID = attachmentID
        self.reservationID = reservationID
        self.provenance = provenance
        self.evidence = evidence
        self.assetMetadata = assetMetadata
        self.intentDigest = intentDigest
        self.operationID = operationID
        self.auditEventID = auditEventID
        self.boundAt = boundAt
    }

    public var resourceKey: ResourceKey { .attachmentEvidenceBinding(for: attachmentID) }

    public static func evidenceDigest(for bytes: Data) -> String {
        let domain = Data("netzwerkdoku.content-safety.sanitized.v1\0evidence\0".utf8)
        return SHA256.hash(data: domain + bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public enum AttachmentEvidenceActivationError: Error, Equatable, Sendable {
    case invalidProvenance
    case invalidQuotaLedger
    case invalidReservationRelease
    case invalidBinding
}

public extension ResourceKey {
    static func attachmentEvidenceQuotaLedger(for workOrderID: ObjectID) -> Self {
        .string("attachment-evidence-quota-ledger:\(workOrderID.description)")
    }

    static func attachmentEvidenceReservationRelease(_ reservationID: ObjectID) -> Self {
        .string("attachment-evidence-reservation-release:\(reservationID.description)")
    }

    static func attachmentEvidenceBinding(for attachmentID: ObjectID) -> Self {
        .string("attachment-evidence-binding:\(attachmentID.description)")
    }
}
