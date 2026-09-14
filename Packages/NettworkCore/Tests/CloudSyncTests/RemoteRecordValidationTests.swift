import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import CloudSync

final class RemoteRecordValidationTests: XCTestCase {
    func testImportedHistoricalReferenceMustBeCanonicalDeletedStagedAndExternal() throws {
        let fixture = try importedHistoricalReferenceFixture()
        let valid = CloudRecordEnvelope(
            resourceKey: fixture.marker.resourceKey,
            workspaceID: fixture.workspaceID,
            recordType: CloudRecordNaming.importedHistoricalReferenceRecordType,
            payload: fixture.payload,
            visibility: .staged(transferID: ObjectID()),
            systemFields: Data([1]),
            changeTag: "marker-v1",
            isDeleted: true
        )
        XCTAssertNoThrow(try CloudRemoteRecordValidator().validate(valid, namespace: fixture.namespace))
        try assertHistoricalReferenceRejectsLiveEnvelope(fixture)
        try assertHistoricalReferenceRejectsTargetScope(fixture)
    }

    private func importedHistoricalReferenceFixture() throws -> HistoricalReferenceFixture {
        let workspaceID = ObjectID()
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork", cloudKitAccountRecordName: "owner", workspaceID: workspaceID,
            zoneName: CloudRecordNaming.zoneName(for: workspaceID), zoneOwnerRecordName: "owner", sessionGeneration: 1)
        let marker = ImportedHistoricalReferenceRecord(
            resourceKey: .string("workspace-bootstrap-sentinel:\(ObjectID().description)"), sourceWorkspaceID: ObjectID(),
            sourceContainerIdentifier: "iCloud.example.source", sourceZoneName: "source-zone", sourceZoneOwnerRecordName: "source-owner",
            auditEventIDs: [ObjectID()], recordedAt: .distantPast)
        return HistoricalReferenceFixture(workspaceID: workspaceID, namespace: namespace, marker: marker, payload: try CloudDeterministicCoding.encode(marker))
    }

    private func assertHistoricalReferenceRejectsLiveEnvelope(_ fixture: HistoricalReferenceFixture) throws {
        let live = CloudRecordEnvelope(
            resourceKey: fixture.marker.resourceKey, workspaceID: fixture.workspaceID, recordType: CloudRecordNaming.importedHistoricalReferenceRecordType,
            payload: fixture.payload, visibility: .staged(transferID: ObjectID()), systemFields: Data([1]), changeTag: "marker-v1")
        XCTAssertThrowsError(try CloudRemoteRecordValidator().validate(live, namespace: fixture.namespace))
    }

    private func assertHistoricalReferenceRejectsTargetScope(_ fixture: HistoricalReferenceFixture) throws {
        let marker = fixture.marker
        let targetScoped = ImportedHistoricalReferenceRecord(
            resourceKey: marker.resourceKey, sourceWorkspaceID: fixture.workspaceID, sourceContainerIdentifier: marker.sourceContainerIdentifier,
            sourceZoneName: marker.sourceZoneName, sourceZoneOwnerRecordName: marker.sourceZoneOwnerRecordName, auditEventIDs: marker.auditEventIDs,
            recordedAt: marker.recordedAt)
        let targetEnvelope = CloudRecordEnvelope(
            resourceKey: marker.resourceKey, workspaceID: fixture.workspaceID,
            recordType: CloudRecordNaming.importedHistoricalReferenceRecordType,
            payload: try CloudDeterministicCoding.encode(targetScoped),
            visibility: .staged(transferID: ObjectID()),
            systemFields: Data([1]),
            changeTag: "marker-v1",
            isDeleted: true
        )
        XCTAssertThrowsError(try CloudRemoteRecordValidator().validate(targetEnvelope, namespace: fixture.namespace))
    }

    func testVerifiedEnvelopeAdmitsFloorPlanBindingWithItsValidatedRecordAsset() throws {
        let workspaceID = ObjectID()
        let namespace = PersistenceNamespace(
            containerIdentifier: "iCloud.example.nettwork",
            cloudKitAccountRecordName: "owner",
            workspaceID: workspaceID,
            zoneName: CloudRecordNaming.zoneName(for: workspaceID),
            zoneOwnerRecordName: "owner",
            sessionGeneration: 1
        )
        let bytes = Data("floor-plan-jpeg".utf8)
        let asset = try CloudRecordAssetDescriptor(
            id: ObjectID(),
            fieldName: "floorPlanAsset",
            sha256: CloudRecordAssetDescriptor.sha256(for: bytes),
            contentType: "image/jpeg",
            byteCount: bytes.count,
            storage: .inline(bytes)
        )
        let operationID = ObjectID()
        let binding = try FloorPlanAssetBindingRecord(
            floorID: ObjectID(),
            workOrderID: ObjectID(),
            assetMetadata: asset.metadata,
            intentDigest: try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 1, count: 32)),
            operationID: operationID,
            auditEventID: AuditEvent.deterministicID(for: operationID),
            boundAt: .distantPast
        )
        let payload = try CloudDeterministicCoding.encode(binding)
        let envelope = CloudRecordEnvelope(
            resourceKey: binding.resourceKey,
            workspaceID: workspaceID,
            recordType: CloudRecordNaming.floorPlanAssetBindingRecordType,
            payload: payload,
            recordAsset: asset,
            systemFields: Data([1]),
            changeTag: "binding-v1"
        )

        XCTAssertEqual(
            try CloudRemoteRecordValidator().validate(envelope, namespace: namespace).envelope,
            envelope
        )
    }
}

private struct HistoricalReferenceFixture {
    let workspaceID: ObjectID
    let namespace: PersistenceNamespace
    let marker: ImportedHistoricalReferenceRecord
    let payload: Data
}
