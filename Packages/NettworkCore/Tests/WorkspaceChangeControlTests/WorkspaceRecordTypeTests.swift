import XCTest

@testable import WorkspaceChangeControl

/// Freezes the persisted wire contract: every record-type name is pinned to its
/// exact string, independent of the constants production code uses.
final class WorkspaceRecordTypeTests: XCTestCase {
    func testDomainRecordTypeNamesAreFrozen() {
        let expected: [(String, String)] = [
            (WorkspaceRecordType.attachmentEvidenceBinding, "NettworkAttachmentEvidenceBinding"),
            (WorkspaceRecordType.attachmentEvidenceQuotaLedger, "NettworkAttachmentEvidenceQuotaLedger"),
            (WorkspaceRecordType.attachmentEvidenceReservationRelease, "NettworkAttachmentEvidenceReservationRelease"),
            (WorkspaceRecordType.auditEvent, "NettworkAuditEvent"),
            (WorkspaceRecordType.cable, "NettworkCable"),
            (WorkspaceRecordType.device, "NettworkDevice"),
            (WorkspaceRecordType.deviceType, "NettworkDeviceType"),
            (WorkspaceRecordType.floorPlanAnchor, "NettworkFloorPlanAnchor"),
            (WorkspaceRecordType.floorPlanAssetBinding, "NettworkFloorPlanAssetBinding"),
            (WorkspaceRecordType.hierarchyTombstone, "NettworkHierarchyTombstone"),
            (WorkspaceRecordType.importedHistoricalReference, "NettworkImportedHistoricalReference"),
            (WorkspaceRecordType.interface, "NettworkInterface"),
            (WorkspaceRecordType.interfaceVLANMembership, "NettworkInterfaceVLANMembership"),
            (WorkspaceRecordType.internalLink, "NettworkInternalLink"),
            (WorkspaceRecordType.inventoryPortStateFact, "NettworkInventoryPortStateFact"),
            (WorkspaceRecordType.ipAddressAssignment, "NettworkIPAddressAssignment"),
            (WorkspaceRecordType.ipAddressRecord, "NettworkIPAddressRecord"),
            (WorkspaceRecordType.location, "NettworkLocation"),
            (WorkspaceRecordType.module, "NettworkModule"),
            (WorkspaceRecordType.moduleTemplate, "NettworkModuleTemplate"),
            (WorkspaceRecordType.operationReceipt, "NettworkOperationReceipt"),
            (WorkspaceRecordType.physicalTopology, "NettworkPhysicalTopology"),
            (WorkspaceRecordType.port, "NettworkPort"),
            (WorkspaceRecordType.portTemplate, "NettworkPortTemplate"),
            (WorkspaceRecordType.prefix, "NettworkPrefix"),
            (WorkspaceRecordType.rack, "NettworkRack"),
            (WorkspaceRecordType.rackPlacement, "NettworkRackPlacement"),
            (WorkspaceRecordType.resourceReservationLock, "NettworkResourceReservationLock"),
            (WorkspaceRecordType.resourceReservationLockSource, "ResourceReservationLock"),
            (WorkspaceRecordType.templatePlacementState, "NettworkTemplatePlacementState"),
            (WorkspaceRecordType.tombstone, "NettworkTombstone"),
            (WorkspaceRecordType.topologyTombstone, "NettworkTopologyTombstone"),
            (WorkspaceRecordType.vlan, "NettworkVLAN"),
            (WorkspaceRecordType.vlanGroup, "NettworkVLANGroup"),
            (WorkspaceRecordType.vrf, "NettworkVRF"),
            (WorkspaceRecordType.workOrder, "NettworkWorkOrder"),
            (WorkspaceRecordType.workspace, "NettworkWorkspace"),
            (WorkspaceRecordType.workspaceAsset, "NettworkWorkspaceAsset"),
            (WorkspaceRecordType.workspaceHierarchy, "NettworkWorkspaceHierarchy"),
            (WorkspaceRecordType.workspaceShare, "NettworkWorkspaceShare"),
            (WorkspaceRecordType.workspaceTransferPrefix, "NettworkWorkspaceTransfer"),
            (WorkspaceRecordType.workspaceTransferSession, "NettworkWorkspaceTransferSession"),
        ]
        for (actual, literal) in expected { XCTAssertEqual(actual, literal) }
        XCTAssertEqual(Set(expected.map(\.0)).count, expected.count)
    }

    func testLegacyRecordTypeNamesAreFrozen() {
        let expected: [(String, String)] = [
            (WorkspaceRecordType.Legacy.cable, "Cable"),
            (WorkspaceRecordType.Legacy.device, "Device"),
            (WorkspaceRecordType.Legacy.deviceType, "DeviceType"),
            (WorkspaceRecordType.Legacy.floorPlanAnchor, "FloorPlanAnchor"),
            (WorkspaceRecordType.Legacy.hierarchyTombstone, "HierarchyTombstone"),
            (WorkspaceRecordType.Legacy.interface, "Interface"),
            (WorkspaceRecordType.Legacy.interfaceVLANMembership, "InterfaceVLANMembership"),
            (WorkspaceRecordType.Legacy.internalLink, "InternalLink"),
            (WorkspaceRecordType.Legacy.ipAddressAssignment, "IPAddressAssignment"),
            (WorkspaceRecordType.Legacy.ipAddressRecord, "IPAddressRecord"),
            (WorkspaceRecordType.Legacy.location, "Location"),
            (WorkspaceRecordType.Legacy.module, "Module"),
            (WorkspaceRecordType.Legacy.moduleTemplate, "ModuleTemplate"),
            (WorkspaceRecordType.Legacy.port, "Port"),
            (WorkspaceRecordType.Legacy.prefix, "Prefix"),
            (WorkspaceRecordType.Legacy.rack, "Rack"),
            (WorkspaceRecordType.Legacy.rackPlacement, "RackPlacement"),
            (WorkspaceRecordType.Legacy.templatePlacementState, "TemplatePlacementState"),
            (WorkspaceRecordType.Legacy.topologyTombstone, "TopologyTombstone"),
            (WorkspaceRecordType.Legacy.vlan, "VLAN"),
            (WorkspaceRecordType.Legacy.vrf, "VRF"),
            (WorkspaceRecordType.Legacy.workspaceHierarchy, "WorkspaceHierarchy"),
        ]
        for (actual, literal) in expected { XCTAssertEqual(actual, literal) }
        XCTAssertEqual(Set(expected.map(\.0)).count, expected.count)
    }
}
