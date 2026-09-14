import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import ImportExport

/// Validation coverage for malformed and incomplete transfer inputs.
final class WorkspaceTransferValidationTests: XCTestCase {
    func testEveryPublishedTableReconstructsToTypedCanonicalEnvelope() throws {
        let records = try WorkspaceTransferRecordReconstruction.records(from: fixtureImports())
        XCTAssertEqual(records.count, CSVTable.allCases.count)
        XCTAssertEqual(Set(records.map(\.recordType)), WorkspaceTransferRecordType.csvReconstructionTypes)
        XCTAssertEqual(records.first(where: { $0.recordType == .address })?.resourceKey, .string(addressID))
        XCTAssertEqual(records.first(where: { $0.recordType == .deviceType })?.schemaVersion, WorkspaceTransferRecord.currentSchemaVersion)
    }

    func testCanonicalJSONLRoundTripProducesAuthoritativeSaveMaterial() throws {
        let location = ImportRecord(
            table: CSVTable.locations.rawValue,
            values: [
                "id": workspaceID.description, "name": "Workspace", "kind": "workspace", "parentID": "", "deletedAt": "",
            ])
        let reconstructed = try WorkspaceTransferRecordReconstruction.records(from: [location])
        let jsonl = try WorkspaceTransferJSONL.encode(reconstructed)
        let decoded = try WorkspaceTransferJSONL.decode(jsonl)
        let validated = try ValidatedWorkspaceTransfer(records: decoded)

        XCTAssertEqual(decoded, reconstructed)
        XCTAssertEqual(validated.saves.count, 1)
        XCTAssertTrue(validated.tombstones.isEmpty)
        XCTAssertEqual(validated.candidate.hierarchy.locations.map(\.id), [workspaceID])
    }

    func testCanonicalHardDeleteMarkerPreservesIdentityWithoutLivePayload() throws {
        let id = Self.id(611)
        let deletedAt = Date(timeIntervalSince1970: 1_725_000_000)
        let marker = WorkspaceHardDeleteMarker(
            resourceKey: .object(id),
            recordType: .device,
            deletedAt: deletedAt
        )
        let record = WorkspaceTransferRecord(
            resourceKey: marker.resourceKey,
            recordType: marker.recordType,
            payload: try WorkspaceTransferCoding.encode(marker),
            tombstone: WorkspaceTransferTombstone(deletedAt: deletedAt)
        )

        let validated = try ValidatedWorkspaceTransfer(records: [try workspaceRecord(), record])

        XCTAssertTrue(validated.candidate.topology.devices.isEmpty)
        XCTAssertEqual(validated.tombstones.count, 1)
        XCTAssertEqual(validated.tombstones[0].resourceKey, .object(id))
        XCTAssertEqual(validated.tombstones[0].encodedTombstone, record.payload)
    }

    func testHardDeleteMarkerRejectsMismatchedResourceIdentity() throws {
        let deletedAt = Date(timeIntervalSince1970: 1_725_000_000)
        let marker = WorkspaceHardDeleteMarker(
            resourceKey: .object(Self.id(612)),
            recordType: .device,
            deletedAt: deletedAt
        )
        let record = WorkspaceTransferRecord(
            resourceKey: .object(Self.id(613)),
            recordType: .device,
            payload: try WorkspaceTransferCoding.encode(marker),
            tombstone: WorkspaceTransferTombstone(deletedAt: deletedAt)
        )

        XCTAssertThrowsError(try WorkspaceTransferCandidate(records: [try workspaceRecord(), record])) { error in
            XCTAssertEqual(error as? WorkspaceTransferValidationError, .tombstoneMetadataMismatch(.device))
        }
    }

    func testReservationLockHardDeleteMarkerUsesTheSameCanonicalPath() throws {
        let lockKey = ResourceKey.reservationLock(for: .object(Self.id(614)))
        let deletedAt = Date(timeIntervalSince1970: 1_725_000_001)
        let marker = WorkspaceHardDeleteMarker(
            resourceKey: lockKey,
            recordType: .reservationLock,
            deletedAt: deletedAt
        )
        let record = WorkspaceTransferRecord(
            resourceKey: lockKey,
            recordType: .reservationLock,
            payload: try WorkspaceTransferCoding.encode(marker),
            tombstone: WorkspaceTransferTombstone(deletedAt: deletedAt)
        )

        XCTAssertEqual(try ValidatedWorkspaceTransfer(records: [try workspaceRecord(), record]).tombstones.count, 1)
    }

    func testJSONLRejectsDuplicateResourceAndNonCanonicalRows() throws {
        let location = Location(id: workspaceID, name: "Workspace", kind: .workspace)
        let payload = try WorkspaceTransferCoding.encode(location)
        let record = WorkspaceTransferRecord(resourceKey: .object(workspaceID), recordType: .location, payload: payload)
        let row = try WorkspaceTransferCoding.encode(record)
        let duplicate = row + Data([0x0A]) + row + Data([0x0A])

        XCTAssertThrowsError(try WorkspaceTransferJSONL.decode(duplicate)) { error in
            XCTAssertEqual(error as? WorkspaceTransferRecordError, .duplicateResource(.object(workspaceID)))
        }
        XCTAssertThrowsError(try WorkspaceTransferJSONL.decode(Data("{ }\n".utf8))) { error in
            XCTAssertEqual(error as? WorkspaceTransferRecordError, .malformedJSONL)
        }
        var nonCanonical = row
        nonCanonical.insert(0x20, at: nonCanonical.index(before: nonCanonical.endIndex))
        nonCanonical.append(0x0A)
        XCTAssertThrowsError(try WorkspaceTransferJSONL.decode(nonCanonical)) { error in
            XCTAssertEqual(error as? WorkspaceTransferRecordError, .nonCanonicalJSONL)
        }
    }

    /// A 201-member candidate splits deterministically into 200 + 1, and its
    /// checkpoint binds the same operation and transfer identities.
    func testStagingPlanUsesBoundedRollingBatchesAndCheckpoints() throws {
        let records = try (1...201).map { index in
            WorkspaceTransferRecord(
                resourceKey: .object(Self.id(1_000 + index)),
                recordType: .location,
                payload: try WorkspaceTransferCoding.encode(Location(id: Self.id(1_000 + index), name: "L\(index)", kind: .floor))
            )
        }
        let transferID = Self.id(500)
        let operationID = Self.id(501)
        let plan = try WorkspaceTransferStagingPlan(transferID: transferID, operationID: operationID, records: Array(records.reversed()))
        let checkpoint = try WorkspaceTransferStagingCheckpoint(plan: plan, completedBatchCount: 1)

        try plan.validate()
        try checkpoint.validates(plan: plan)
        XCTAssertEqual(plan.batches.map { $0.members.count }, [200, 1])
        XCTAssertEqual(plan.members.map(\.id), plan.members.sorted { $0.id < $1.id }.map(\.id))
        XCTAssertEqual(checkpoint.completedMemberCount, 200)
        XCTAssertEqual(checkpoint.transferID, transferID)
        XCTAssertEqual(checkpoint.operationID, operationID)
    }

    func testRejectsNonCanonicalUUIDEnumNumberAndAddressIdentity() {
        var badUUID = fixtureImports()[0]
        let nonCanonicalUUID = "A0000000-0000-0000-0000-000000000001"
        badUUID.values["id"] = nonCanonicalUUID
        XCTAssertThrowsError(try WorkspaceTransferRecordReconstruction.record(from: badUUID)) { error in
            XCTAssertEqual(error as? WorkspaceTransferRecordError, .invalidUUID(table: CSVTable.locations.rawValue, field: "id", value: nonCanonicalUUID))
        }

        var badEnum = fixtureImports().first { $0.table == CSVTable.ports.rawValue }!
        badEnum.values["medium"] = "wireless"
        XCTAssertThrowsError(try WorkspaceTransferRecordReconstruction.record(from: badEnum)) { error in
            XCTAssertEqual(error as? WorkspaceTransferRecordError, .invalidEnum(table: CSVTable.ports.rawValue, field: "medium", value: "wireless"))
        }

        var badNumber = fixtureImports().first { $0.table == CSVTable.floorPlanAnchors.rawValue }!
        badNumber.values["x"] = "nan"
        XCTAssertThrowsError(try WorkspaceTransferRecordReconstruction.record(from: badNumber)) { error in
            XCTAssertEqual(error as? WorkspaceTransferRecordError, .invalidNumber(table: CSVTable.floorPlanAnchors.rawValue, field: "x", value: "nan"))
        }

        var badAddress = fixtureImports().first { $0.table == CSVTable.addresses.rawValue }!
        badAddress.values["id"] = "ip:forged"
        XCTAssertThrowsError(try WorkspaceTransferRecordReconstruction.record(from: badAddress)) { error in
            XCTAssertEqual(error as? WorkspaceTransferRecordError, .nonCanonicalAddressID(expected: addressID, actual: "ip:forged"))
        }
    }

    func testExpandedSchemaRepresentsPlacementModulesAssignmentsAndVLANGroups() throws {
        let records = try WorkspaceTransferRecordReconstruction.records(from: fixtureImports())

        XCTAssertEqual(records.first(where: { $0.recordType == .rackPlacement })?.resourceKey, .rackPlacement(deviceID: deviceID))
        XCTAssertEqual(records.first(where: { $0.recordType == .moduleTemplate })?.resourceKey, .object(moduleTemplateID))
        XCTAssertEqual(records.first(where: { $0.recordType == .module })?.resourceKey, .object(moduleID))
        XCTAssertEqual(records.first(where: { $0.recordType == .vlanGroup })?.resourceKey, .object(vlanGroupID))
        XCTAssertEqual(records.first(where: { $0.recordType == .assignment })?.resourceKey, .object(assignmentID))
    }

    func testRejectsPublishedInternalLinkKindThatCannotBeRepresentedByTheDomain() {
        var link = fixtureImports().first { $0.table == CSVTable.internalLinks.rawValue }!
        link.values["kind"] = "legacy-kind"
        XCTAssertThrowsError(try WorkspaceTransferRecordReconstruction.record(from: link)) { error in
            XCTAssertEqual(error as? WorkspaceTransferRecordError, .unsupportedPublishedColumn(table: CSVTable.internalLinks.rawValue, field: "kind"))
        }
    }

    func testAcceptsAttachmentQuotaLedgerMatchingAllWorkOrderBindings() throws {
        let records = try attachmentQuotaRecords(
            attachmentByteCounts: [3, 5],
            ledgerAttachmentCount: 2,
            ledgerTotalBytes: 8
        )

        XCTAssertEqual(try WorkspaceTransferCandidate(records: records).attachmentEvidenceBindings.count, 2)
    }

    func testRejectsAttachmentQuotaLedgerUndercount() throws {
        let records = try attachmentQuotaRecords(
            attachmentByteCounts: [3, 5],
            ledgerAttachmentCount: 1,
            ledgerTotalBytes: 8
        )

        XCTAssertThrowsError(try WorkspaceTransferCandidate(records: records)) { error in
            XCTAssertEqual(error as? WorkspaceTransferValidationError, .operationalValidationFailed)
        }
    }

    func testRejectsAttachmentQuotaLedgerOvercount() throws {
        let records = try attachmentQuotaRecords(
            attachmentByteCounts: [3, 5],
            ledgerAttachmentCount: 3,
            ledgerTotalBytes: 8
        )

        XCTAssertThrowsError(try WorkspaceTransferCandidate(records: records)) { error in
            XCTAssertEqual(error as? WorkspaceTransferValidationError, .operationalValidationFailed)
        }
    }

    func testRejectsAttachmentQuotaLedgerOverstatedTotalBytes() throws {
        let records = try attachmentQuotaRecords(
            attachmentByteCounts: [3, 5],
            ledgerAttachmentCount: 2,
            ledgerTotalBytes: 9
        )

        XCTAssertThrowsError(try WorkspaceTransferCandidate(records: records)) { error in
            XCTAssertEqual(error as? WorkspaceTransferValidationError, .operationalValidationFailed)
        }
    }

    func testRejectsAttachmentQuotaLedgerWithoutBindings() throws {
        let records = try attachmentQuotaRecords(
            attachmentByteCounts: [],
            ledgerAttachmentCount: 0,
            ledgerTotalBytes: 0
        )

        XCTAssertThrowsError(try WorkspaceTransferCandidate(records: records)) { error in
            XCTAssertEqual(error as? WorkspaceTransferValidationError, .operationalValidationFailed)
        }
    }

    private func attachmentQuotaRecords(
        attachmentByteCounts: [Int],
        ledgerAttachmentCount: Int,
        ledgerTotalBytes: Int
    ) throws -> [WorkspaceTransferRecord] {
        let workOrderID = ObjectID()
        let intentDigest = try IntentDigest(algorithm: .sha256, bytes: Array(repeating: 7, count: 32))
        let attachmentValues = try attachmentByteCounts.enumerated().map {
            try attachmentValue(index: $0, byteCount: $1, workOrderID: workOrderID, intentDigest: intentDigest)
        }
        let workOrder = WorkOrder(
            id: workOrderID,
            kind: .connect,
            title: "Attach evidence",
            status: .completed,
            creatorID: "owner",
            intentDigest: intentDigest,
            evidenceHashes: attachmentValues.map { $0.0.evidence }
        )
        let ledger = try AttachmentEvidenceQuotaLedger(
            workOrderID: workOrderID,
            attachmentCount: ledgerAttachmentCount,
            totalBytes: ledgerTotalBytes,
            updatedAt: .distantPast
        )
        return try [
            workspaceRecord(),
            transferRecord(workOrder, type: .workOrder, resourceKey: .object(workOrder.id)),
            transferRecord(ledger, type: .attachmentEvidenceQuotaLedger, resourceKey: ledger.resourceKey),
        ]
            + attachmentValues.flatMap { value in
                [
                    try transferRecord(value.0, type: .attachmentEvidenceBinding, resourceKey: value.0.resourceKey),
                    try transferRecord(value.1, type: .attachmentEvidenceReservationRelease, resourceKey: value.1.resourceKey),
                    try transferRecord(value.2, type: .operationReceipt, resourceKey: value.2.id),
                ]
            }
    }

    private func transferRecord<T: Encodable>(
        _ value: T,
        type: WorkspaceTransferRecordType,
        resourceKey: ResourceKey
    ) throws -> WorkspaceTransferRecord {
        WorkspaceTransferRecord(
            resourceKey: resourceKey,
            recordType: type,
            payload: try WorkspaceTransferCoding.encode(value)
        )
    }

    private func workspaceRecord() throws -> WorkspaceTransferRecord {
        let workspace = Location(id: Self.id(600), name: "Workspace", kind: .workspace)
        return try transferRecord(workspace, type: .location, resourceKey: .object(workspace.id))
    }

    private func attachmentValue(index: Int, byteCount: Int, workOrderID: ObjectID, intentDigest: IntentDigest) throws -> (
        AttachmentEvidenceBindingRecord, AttachmentEvidenceReservationRelease, OperationReceipt
    ) {
        let attachmentID = ObjectID()
        let reservationID = ObjectID()
        let operationID = ObjectID()
        let bytes = Data(repeating: UInt8(index + 1), count: byteCount)
        let asset = try CloudRecordAssetDescriptor(
            id: attachmentID, fieldName: "sanitizedAsset", sha256: CloudRecordAssetDescriptor.sha256(for: bytes), contentType: "image/jpeg",
            byteCount: bytes.count, storage: .inline(bytes))
        let provenance = try AttachmentEvidenceProvenanceRecord(
            domainSeparatedSHA256: AttachmentEvidenceBindingRecord.evidenceDigest(for: bytes), purpose: "evidence", contentType: "image/jpeg",
            byteCount: bytes.count)
        let domain = Data("netzwerkdoku.content-safety.sanitized.v1\0evidence\0".utf8)
        let evidence = EvidenceHash(
            id: attachmentID, digest: try IntentDigest(algorithm: .sha256, bytes: Array(SHA256.hash(data: domain + bytes))), contentType: "image/jpeg")
        let binding = try AttachmentEvidenceBindingRecord(
            workOrderID: workOrderID, attachmentID: attachmentID, reservationID: reservationID, provenance: provenance, evidence: evidence,
            assetMetadata: asset.metadata, intentDigest: intentDigest, operationID: operationID, auditEventID: AuditEvent.deterministicID(for: operationID),
            boundAt: .distantPast)
        let release = try AttachmentEvidenceReservationRelease(
            id: reservationID, workOrderID: workOrderID, attachmentID: attachmentID, reservedCount: 1, reservedBytes: byteCount, expiresAt: .distantFuture,
            releasedAt: .distantPast, operationID: operationID)
        let receipt = OperationReceipt(
            workspaceZone: AuthoritativeWorkspaceZone(
                workspaceID: ObjectID(), containerIdentifier: "iCloud.example.nettwork", zoneName: "nettwork.workspace.test", zoneOwnerRecordName: "owner"),
            operationID: operationID, intentDigest: intentDigest, auditEventID: binding.auditEventID)
        return (binding, release, receipt)
    }

    private func fixtureImports() -> [ImportRecord] {
        topologyFixtureImports() + addressingFixtureImports()
    }

    private func topologyFixtureImports() -> [ImportRecord] {
        let customFields = json([CustomFieldValue]())
        let portTemplates = json([PortTemplate]())
        let slots = json([ModuleSlotTemplate]())
        let schemas = json([CustomFieldSchema]())
        let record: (CSVTable, [String: String]) -> ImportRecord = { .init(table: $0.rawValue, values: $1) }
        return [
            record(.locations, ["id": workspaceID.description, "name": "Workspace", "kind": "workspace", "parentID": "", "deletedAt": ""]),
            record(.racks, ["id": rackID.description, "assetCode": "RACK-1", "locationID": workspaceID.description, "heightRU": "42", "deletedAt": ""]),
            record(
                .deviceTypes,
                [
                    "id": deviceTypeID.description, "name": "Router", "kind": "generic", "customFieldsJSON": customFields, "version": "1", "rackHeightRU": "1",
                    "portTemplatesJSON": portTemplates, "moduleSlotsJSON": slots, "customFieldSchemasJSON": schemas,
                ]),
            record(
                .moduleTemplates,
                ["id": moduleTemplateID.description, "name": "Line card", "portsJSON": portTemplates, "version": "1", "customFieldSchemasJSON": schemas]),
            record(
                .devices,
                [
                    "id": deviceID.description, "assetCode": "RTR-1", "name": "Edge", "typeID": deviceTypeID.description, "rackID": "",
                    "customFieldsJSON": customFields, "templateSnapshotJSON": "",
                ]),
            record(
                .modules,
                [
                    "id": moduleID.description, "deviceID": deviceID.description, "templateID": moduleTemplateID.description, "slot": "slot-1",
                    "templateSnapshotJSON": "", "customFieldsJSON": customFields,
                ]),
            record(.rackPlacements, ["deviceID": deviceID.description, "rackID": rackID.description, "startRU": "1", "heightRU": "1", "face": "front"]),
            record(
                .ports,
                [
                    "id": portID.description, "deviceID": deviceID.description, "moduleID": "", "label": "Gi0/1", "medium": "copper", "connector": "rj45",
                    "face": "front", "fiberMode": "", "availability": "available", "customFieldsJSON": customFields,
                ]),
            record(.internalLinks, ["id": linkID.description, "endpointA": portID.description, "endpointB": secondPortID.description, "kind": ""]),
            record(
                .cables,
                [
                    "id": cableID.description, "assetCode": "C-1", "endpointA": portID.description, "connectorA": "rj45", "endpointB": secondPortID.description,
                    "connectorB": "rj45", "medium": "copper", "kind": "patchCord", "status": "installed", "color": "", "lengthMeters": "1.5",
                ]),
        ]
    }

    private func addressingFixtureImports() -> [ImportRecord] {
        let ranges = json([ReservedAddressRange]())
        let record: (CSVTable, [String: String]) -> ImportRecord = { .init(table: $0.rawValue, values: $1) }
        return [
            record(.vrfs, ["id": vrfID.description, "name": "Default", "revision": "0", "state": "active", "tombstonedAt": ""]),
            record(
                .prefixes,
                [
                    "id": prefixID.description, "vrfID": vrfID.description, "cidr": "192.0.2.0/24", "name": "Docs", "reservedRangesJSON": ranges,
                    "state": "active", "tombstonedAt": "",
                ]),
            record(
                .addresses,
                ["id": addressID, "vrfID": vrfID.description, "address": "192.0.2.10", "assignedInterfaceID": "", "state": "active", "tombstonedAt": ""]),
            record(.vlanGroups, ["id": vlanGroupID.description, "name": "Campus", "state": "active", "tombstonedAt": ""]),
            record(
                .vlans, ["id": vlanID.description, "groupID": vlanGroupID.description, "number": "100", "name": "Users", "state": "active", "tombstonedAt": ""]),
            record(
                .interfaces,
                [
                    "id": interfaceID.description, "deviceID": deviceID.description, "physicalPortID": "", "name": "Lo0", "mode": "routed", "kind": "loopback",
                    "vlanID": "", "state": "active", "tombstonedAt": "",
                ]),
            record(
                .assignments,
                [
                    "id": assignmentID.description, "addressID": addressID, "interfaceID": interfaceID.description, "isPrimary": "true", "state": "active",
                    "tombstonedAt": "",
                ]),
            record(
                .floorPlanAnchors,
                ["id": anchorID.description, "objectID": workspaceID.description, "floorID": workspaceID.description, "x": "0.5", "y": "0.5"]),
            record(
                .memberships,
                [
                    "id": membershipID.description, "interfaceID": interfaceID.description, "vlanID": vlanID.description, "isNative": "false",
                    "state": "active", "tombstonedAt": "",
                ]),
        ]
    }

    private func json<T: Encodable>(_ value: T) -> String {
        String(decoding: try! WorkspaceTransferCoding.encode(value), as: UTF8.self)
    }

    private static func id(_ suffix: Int) -> ObjectID {
        ObjectID(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!)
    }

    private var workspaceID: ObjectID { Self.id(1) }
    private var rackID: ObjectID { Self.id(2) }
    private var deviceTypeID: ObjectID { Self.id(3) }
    private var moduleTemplateID: ObjectID { Self.id(16) }
    private var deviceID: ObjectID { Self.id(4) }
    private var moduleID: ObjectID { Self.id(17) }
    private var portID: ObjectID { Self.id(5) }
    private var secondPortID: ObjectID { Self.id(6) }
    private var linkID: ObjectID { Self.id(7) }
    private var cableID: ObjectID { Self.id(8) }
    private var vrfID: ObjectID { Self.id(9) }
    private var prefixID: ObjectID { Self.id(10) }
    private var vlanGroupID: ObjectID { Self.id(11) }
    private var vlanID: ObjectID { Self.id(12) }
    private var interfaceID: ObjectID { Self.id(13) }
    private var anchorID: ObjectID { Self.id(14) }
    private var membershipID: ObjectID { Self.id(15) }
    private var assignmentID: ObjectID { Self.id(18) }
    private var addressID: String { IPAddressRecord.deterministicRecordName(vrfID: vrfID, address: IPAddress(parsing: "192.0.2.10")!) }
}
