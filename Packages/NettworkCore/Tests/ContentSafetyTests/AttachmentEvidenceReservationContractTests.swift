import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import ContentSafety

final class AttachmentEvidenceReservationContractTests: XCTestCase {
    func testOwnerMatchesOnlyTheCompleteAttachmentNamespace() {
        let workspace = ObjectID(UUID(uuidString: "10000000-0000-0000-0000-000000000001")!)
        let owner = AttachmentEvidenceOwner(
            workOrderID: ObjectID(),
            namespace: namespace(workspace: workspace, generation: 1)
        )

        XCTAssertTrue(owner.matches(AttachmentNamespace(account: account(workspace: workspace, generation: 1))))
        XCTAssertFalse(owner.matches(AttachmentNamespace(account: account(workspace: workspace, generation: 2))))
    }

    func testBindingIntentReceiptUsesTheDeterministicAuditIdentity() throws {
        let context = authorization()
        let attachmentID = ObjectID()
        let evidence = try EvidenceHash(
            id: attachmentID,
            digest: IntentDigest(algorithm: .sha256, bytes: Array(repeating: 7, count: 32)),
            contentType: "image/jpeg"
        )
        let intent = try AttachmentEvidenceBindingIntent(
            owner: AttachmentEvidenceOwner(workOrderID: ObjectID(), namespace: context.account.namespace),
            attachmentID: attachmentID,
            evidence: evidence,
            authorization: context
        )

        XCTAssertEqual(intent.expectedReceipt.operationID, context.operationID)
        XCTAssertEqual(intent.expectedReceipt.auditEventID, AuditEvent.deterministicID(for: context.operationID))
        XCTAssertEqual(intent.expectedReceipt.intentDigest, intent.digest)
    }

    private func authorization() -> AuthorizedOperationContext {
        let account = account(workspace: ObjectID(), generation: 1)
        return AuthorizedOperationContext(
            operationID: ObjectID(),
            account: account,
            actor: ActorContext(
                cloudKitUserRecordName: "account-a",
                role: .technician,
                installationID: "ipad-a",
                sessionGeneration: 1
            ),
            action: .createAttachment
        )
    }

    private func account(workspace: ObjectID, generation: UInt64) -> AccountContext {
        AccountContext(
            namespace: namespace(workspace: workspace, generation: generation),
            databaseScope: .ownerPrivate,
            sharePermission: .owner,
            verifiedAt: .distantPast
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
