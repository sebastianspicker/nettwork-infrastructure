import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Persistence

final class AttachmentEvidencePersistenceContractTests: XCTestCase {
    func testPolicyHasNoImplicitOrganizationQuotaAndRejectsInvalidLimits() throws {
        XCTAssertThrowsError(
            try AttachmentEvidenceQuotaPolicy(
                maximumAttachmentCount: 0,
                maximumTotalBytes: 1,
                reservationLifetime: 1
            )
        )
        XCTAssertThrowsError(
            try AttachmentEvidenceQuotaPolicy(
                maximumAttachmentCount: 1,
                maximumTotalBytes: 0,
                reservationLifetime: 1
            )
        )
        XCTAssertThrowsError(
            try AttachmentEvidenceQuotaPolicy(
                maximumAttachmentCount: 1,
                maximumTotalBytes: 1,
                reservationLifetime: 0
            )
        )
        let policy = try AttachmentEvidenceQuotaPolicy(
            maximumAttachmentCount: 3,
            maximumTotalBytes: 1_024,
            reservationLifetime: 60
        )
        XCTAssertEqual(policy.maximumAttachmentCount, 3)
        XCTAssertEqual(policy.maximumTotalBytes, 1_024)
    }

    func testEvidenceNamespaceIncludesSessionGenerationAndProvenanceIsRestrictedToSanitizedJPEG() throws {
        let workspace = ObjectID(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
        let first = namespace(workspace: workspace, generation: 1)
        let renewed = namespace(workspace: workspace, generation: 2)
        let reservation = try AttachmentEvidenceReservationMetadata(
            namespace: first,
            workOrderID: ObjectID(),
            attachmentID: ObjectID(),
            reservedCount: 1,
            reservedBytes: 42,
            createdAt: .distantPast,
            expiresAt: .distantFuture
        )
        XCTAssertEqual(reservation.namespace, first)
        XCTAssertNotEqual(
            PersistenceNamespaceKey.storageKey(namespace: first, identity: "attachment-evidence"),
            PersistenceNamespaceKey.storageKey(namespace: renewed, identity: "attachment-evidence")
        )
        XCTAssertNoThrow(
            try SanitizedAttachmentProvenance(
                domainSeparatedSHA256: String(repeating: "a", count: 64),
                purpose: "evidence",
                contentType: "image/jpeg",
                byteCount: 42
            )
        )
        XCTAssertThrowsError(
            try SanitizedAttachmentProvenance(
                domainSeparatedSHA256: String(repeating: "a", count: 64),
                purpose: "floorPlan",
                contentType: "image/jpeg",
                byteCount: 42
            )
        )
    }

    private func namespace(workspace: ObjectID, generation: UInt64) -> PersistenceNamespace {
        PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "account-a",
            workspaceID: workspace,
            zoneName: "workspace-zone",
            zoneOwnerRecordName: "workspace-owner",
            sessionGeneration: generation
        )
    }
}
