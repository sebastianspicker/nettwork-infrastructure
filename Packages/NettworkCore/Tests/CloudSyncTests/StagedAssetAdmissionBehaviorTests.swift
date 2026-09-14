import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class StagedAssetAdmissionBehaviorTests: XCTestCase {
    func testQuotaPolicyRejectsInvalidBounds() throws {
        XCTAssertThrowsError(
            try CloudStagedAssetQuotaPolicy(
                maximumAssetsPerTransfer: 0,
                maximumBytesPerTransfer: 1,
                maximumBytesPerNamespace: 1
            ))
        XCTAssertThrowsError(
            try CloudStagedAssetQuotaPolicy(
                maximumAssetsPerTransfer: 1,
                maximumBytesPerTransfer: 2,
                maximumBytesPerNamespace: 1
            ))
    }

    func testQuotaPolicyRetainsTheValidatedTransferAndNamespaceLimits() throws {
        let policy = try CloudStagedAssetQuotaPolicy(
            maximumAssetsPerTransfer: 3,
            maximumBytesPerTransfer: 128,
            maximumBytesPerNamespace: 256
        )

        XCTAssertEqual(policy.maximumAssetsPerTransfer, 3)
        XCTAssertEqual(policy.maximumBytesPerTransfer, 128)
        XCTAssertEqual(policy.maximumBytesPerNamespace, 256)
    }

    func testStagedMaintenanceFactsUseTheExactEnvelopeCommitment() throws {
        let workspaceID = ObjectID()
        let transferID = ObjectID()
        let envelope = CloudRecordEnvelope(
            resourceKey: .string("staged-asset"),
            workspaceID: workspaceID,
            recordType: CloudRecordNaming.workspaceAssetRecordType,
            payload: Data("asset metadata".utf8),
            visibility: .staged(transferID: transferID),
            systemFields: Data(),
            changeTag: "asset-v1"
        )

        let batch = try CloudMirrorMaintenanceFactBuilder.build(
            for: [VerifiedCloudRecord(envelope: envelope)]
        )

        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(batch.records[0].transferMember?.transferID, transferID)
        XCTAssertEqual(batch.records[0].transferMember?.resourceKey, envelope.resourceKey)
        XCTAssertEqual(batch.records[0].transferMember?.digest, CloudStagedTransferCommitment.member(envelope))
    }
}
