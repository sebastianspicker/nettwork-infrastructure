/// Canonical record-type names for every persisted and remote workspace record.
///
/// These strings are a persisted wire contract: they appear in CloudKit record
/// types, the local mirror, archives, and staged transfers. Changing a value
/// orphans existing data, so each name is spelled once, here. The exception is
/// `WorkspaceTransferRecordType`, whose raw values Swift requires as literals;
/// `WorkspaceTransferRecordTypeNamingTests` pins them to these constants.
public enum WorkspaceRecordType {
    public static let attachmentEvidenceBinding = "NettworkAttachmentEvidenceBinding"
    public static let attachmentEvidenceQuotaLedger = "NettworkAttachmentEvidenceQuotaLedger"
    public static let attachmentEvidenceReservationRelease = "NettworkAttachmentEvidenceReservationRelease"
    public static let auditEvent = "NettworkAuditEvent"
    public static let cable = "NettworkCable"
    public static let device = "NettworkDevice"
    public static let deviceType = "NettworkDeviceType"
    public static let floorPlanAnchor = "NettworkFloorPlanAnchor"
    public static let floorPlanAssetBinding = "NettworkFloorPlanAssetBinding"
    public static let hierarchyTombstone = "NettworkHierarchyTombstone"
    public static let importedHistoricalReference = "NettworkImportedHistoricalReference"
    public static let interface = "NettworkInterface"
    public static let interfaceVLANMembership = "NettworkInterfaceVLANMembership"
    public static let internalLink = "NettworkInternalLink"
    public static let inventoryPortStateFact = "NettworkInventoryPortStateFact"
    public static let ipAddressAssignment = "NettworkIPAddressAssignment"
    public static let ipAddressRecord = "NettworkIPAddressRecord"
    public static let location = "NettworkLocation"
    public static let module = "NettworkModule"
    public static let moduleTemplate = "NettworkModuleTemplate"
    public static let operationReceipt = "NettworkOperationReceipt"
    public static let physicalTopology = "NettworkPhysicalTopology"
    public static let port = "NettworkPort"
    public static let portTemplate = "NettworkPortTemplate"
    public static let prefix = "NettworkPrefix"
    public static let rack = "NettworkRack"
    public static let rackPlacement = "NettworkRackPlacement"
    public static let resourceReservationLock = "NettworkResourceReservationLock"
    /// The unprefixed source type that reservation lock saves and tombstones
    /// carry in authoritative mutations. `CloudRecordNaming.canonicalRecordType`
    /// maps it to `resourceReservationLock` at the CloudKit boundary.
    public static let resourceReservationLockSource = "ResourceReservationLock"
    public static let templatePlacementState = "NettworkTemplatePlacementState"
    public static let tombstone = "NettworkTombstone"
    public static let topologyTombstone = "NettworkTopologyTombstone"
    public static let vlan = "NettworkVLAN"
    public static let vlanGroup = "NettworkVLANGroup"
    public static let vrf = "NettworkVRF"
    public static let workOrder = "NettworkWorkOrder"
    public static let workspace = "NettworkWorkspace"
    public static let workspaceAsset = "NettworkWorkspaceAsset"
    public static let workspaceHierarchy = "NettworkWorkspaceHierarchy"
    public static let workspaceShare = "NettworkWorkspaceShare"
    /// Prefix shared by every staged workspace-transfer record type; not itself a record type.
    public static let workspaceTransferPrefix = "NettworkWorkspaceTransfer"
    public static let workspaceTransferSession = "NettworkWorkspaceTransferSession"

    /// Unprefixed names accepted for aggregates written by older builds. Read
    /// paths still match them; they are a persisted wire contract like the names above.
    public enum Legacy {
        public static let cable = "Cable"
        public static let device = "Device"
        public static let deviceType = "DeviceType"
        public static let floorPlanAnchor = "FloorPlanAnchor"
        public static let hierarchyTombstone = "HierarchyTombstone"
        public static let interface = "Interface"
        public static let interfaceVLANMembership = "InterfaceVLANMembership"
        public static let internalLink = "InternalLink"
        public static let ipAddressAssignment = "IPAddressAssignment"
        public static let ipAddressRecord = "IPAddressRecord"
        public static let location = "Location"
        public static let module = "Module"
        public static let moduleTemplate = "ModuleTemplate"
        public static let port = "Port"
        public static let prefix = "Prefix"
        public static let rack = "Rack"
        public static let rackPlacement = "RackPlacement"
        public static let templatePlacementState = "TemplatePlacementState"
        public static let topologyTombstone = "TopologyTombstone"
        public static let vlan = "VLAN"
        public static let vrf = "VRF"
        public static let workspaceHierarchy = "WorkspaceHierarchy"
    }
}
