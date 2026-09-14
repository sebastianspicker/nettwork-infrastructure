import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class CloudMirrorMaintenanceFactBuilderTests: XCTestCase {
    private let workspaceID = ObjectID()

    func testLiveLocationProducesForwardReferenceEdge() throws {
        let locationID = ObjectID()
        let parentID = ObjectID()
        let envelope = try locationEnvelope(id: locationID, parentID: parentID)

        let batch = try CloudMirrorMaintenanceFactBuilder.build(
            for: [VerifiedCloudRecord(envelope: envelope)]
        )

        XCTAssertEqual(batch.records.count, 1)
        XCTAssertEqual(
            batch.records[0].references,
            [LocalMirrorReferenceEdge(source: .object(locationID), target: .object(parentID))]
        )
        XCTAssertNil(batch.records[0].transferMember)
    }

    func testStagedLiveRecordCreatesExactTransferMemberDigest() throws {
        let transferID = ObjectID()
        let envelope = record(
            resourceKey: .string("staged-live"),
            visibility: .staged(transferID: transferID)
        )

        let batch = try CloudMirrorMaintenanceFactBuilder.build(
            for: [VerifiedCloudRecord(envelope: envelope)]
        )

        XCTAssertEqual(
            batch.records[0].transferMember,
            LocalMirrorTransferMember(
                transferID: transferID,
                resourceKey: envelope.resourceKey,
                digest: CloudStagedTransferCommitment.member(envelope)
            )
        )
    }

    func testStagedTombstoneRetainsTransferMembership() throws {
        let locationID = ObjectID()
        let parentID = ObjectID()
        let transferID = ObjectID()
        let envelope = try locationEnvelope(
            id: locationID,
            parentID: parentID,
            visibility: .staged(transferID: transferID),
            isDeleted: true
        )

        let batch = try CloudMirrorMaintenanceFactBuilder.build(
            for: [VerifiedCloudRecord(envelope: envelope)]
        )

        XCTAssertEqual(batch.records[0].references, [])
        XCTAssertEqual(batch.records[0].transferMember?.transferID, transferID)
        XCTAssertEqual(batch.records[0].transferMember?.digest, CloudStagedTransferCommitment.member(envelope))
    }

    func testDeletionClearsPreviouslyExtractableForwardReferences() throws {
        let locationID = ObjectID()
        let envelope = try locationEnvelope(
            id: locationID,
            parentID: ObjectID(),
            isDeleted: true
        )

        let batch = try CloudMirrorMaintenanceFactBuilder.build(
            for: [VerifiedCloudRecord(envelope: envelope)]
        )

        XCTAssertEqual(batch.records[0].references, [])
    }

    func testDuplicateResourceKeyIsRejectedBeforeFactConstruction() {
        let duplicateKey = ResourceKey.string("duplicate")

        XCTAssertThrowsError(
            try CloudMirrorMaintenanceFactBuilder.build(
                for: [
                    VerifiedCloudRecord(envelope: record(resourceKey: duplicateKey)),
                    VerifiedCloudRecord(envelope: record(resourceKey: duplicateKey)),
                ]
            )
        ) { error in
            guard let adapterError = error as? CloudMirrorAdapterError,
                case let .malformedPayload(resourceKey, reason) = adapterError
            else {
                return XCTFail("Expected duplicate mirror resource key error, got \(error)")
            }
            XCTAssertEqual(resourceKey, duplicateKey)
            XCTAssertEqual(reason, "duplicate mirror resource key")
        }
    }

    func testOneRecordInputProducesExactlyOneCompleteMaintenanceRecord() throws {
        let envelope = record(resourceKey: .string("single-record"))

        let batch = try CloudMirrorMaintenanceFactBuilder.build(
            for: [VerifiedCloudRecord(envelope: envelope)]
        )

        XCTAssertTrue(batch.isComplete)
        XCTAssertEqual(
            batch.records,
            [
                LocalMirrorMaintenanceRecord(resourceKey: envelope.resourceKey)
            ])
    }

    private func locationEnvelope(
        id: ObjectID,
        parentID: ObjectID,
        visibility: WorkspaceRecordVisibility = .live,
        isDeleted: Bool = false
    ) throws -> CloudRecordEnvelope {
        CloudRecordEnvelope(
            resourceKey: .object(id),
            workspaceID: workspaceID,
            recordType: "NettworkLocation",
            payload: try CloudDeterministicCoding.encode(
                Location(id: id, name: "Maintenance fixture", parentID: parentID)
            ),
            visibility: visibility,
            systemFields: Data(),
            changeTag: "maintenance-fixture",
            isDeleted: isDeleted
        )
    }

    private func record(
        resourceKey: ResourceKey,
        visibility: WorkspaceRecordVisibility = .live
    ) -> CloudRecordEnvelope {
        CloudRecordEnvelope(
            resourceKey: resourceKey,
            workspaceID: workspaceID,
            recordType: CloudRecordNaming.workspaceAssetRecordType,
            payload: Data(),
            visibility: visibility,
            systemFields: Data(),
            changeTag: "maintenance-fixture"
        )
    }
}
