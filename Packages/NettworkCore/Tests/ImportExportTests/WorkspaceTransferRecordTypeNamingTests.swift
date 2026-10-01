import XCTest

@testable import ImportExport
@testable import WorkspaceChangeControl

/// The enum raw values must stay literals, so this pins them to the shared names.
final class WorkspaceTransferRecordTypeNamingTests: XCTestCase {
    func testRawValuesMatchSharedRecordTypeNames() {
        let expected: [(WorkspaceTransferRecordType, String)] = [
            (.location, WorkspaceRecordType.location),
            (.rack, WorkspaceRecordType.rack),
            (.deviceType, WorkspaceRecordType.deviceType),
            (.portTemplate, WorkspaceRecordType.portTemplate),
            (.moduleTemplate, WorkspaceRecordType.moduleTemplate),
            (.device, WorkspaceRecordType.device),
            (.module, WorkspaceRecordType.module),
            (.rackPlacement, WorkspaceRecordType.rackPlacement),
            (.port, WorkspaceRecordType.port),
            (.internalLink, WorkspaceRecordType.internalLink),
            (.cable, WorkspaceRecordType.cable),
            (.vrf, WorkspaceRecordType.vrf),
            (.prefix, WorkspaceRecordType.prefix),
            (.address, WorkspaceRecordType.ipAddressRecord),
            (.vlanGroup, WorkspaceRecordType.vlanGroup),
            (.vlan, WorkspaceRecordType.vlan),
            (.interface, WorkspaceRecordType.interface),
            (.assignment, WorkspaceRecordType.ipAddressAssignment),
            (.floorPlanAnchor, WorkspaceRecordType.floorPlanAnchor),
            (.membership, WorkspaceRecordType.interfaceVLANMembership),
            (.workOrder, WorkspaceRecordType.workOrder),
            (.reservationLock, WorkspaceRecordType.resourceReservationLock),
            (.operationReceipt, WorkspaceRecordType.operationReceipt),
            (.attachmentEvidenceQuotaLedger, WorkspaceRecordType.attachmentEvidenceQuotaLedger),
            (.attachmentEvidenceReservationRelease, WorkspaceRecordType.attachmentEvidenceReservationRelease),
            (.attachmentEvidenceBinding, WorkspaceRecordType.attachmentEvidenceBinding),
            (.floorPlanAssetBinding, WorkspaceRecordType.floorPlanAssetBinding),
            (.importedHistoricalReference, WorkspaceRecordType.importedHistoricalReference),
        ]
        XCTAssertEqual(expected.count, WorkspaceTransferRecordType.allCases.count)
        for (type, name) in expected { XCTAssertEqual(type.rawValue, name) }
    }
}
