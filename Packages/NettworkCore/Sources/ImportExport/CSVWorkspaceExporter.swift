import Foundation
import NetworkModel
import WorkspaceChangeControl

/// The complete read-only domain projection represented by a CSV workspace
/// export. It deliberately excludes operational and audit-only records: CSV
/// is the published domain interchange format, not an archive replacement.
public struct CSVWorkspaceExportProjection: Sendable {
    public let locations: [Location]
    public let racks: [Rack]
    public let deviceTypes: [DeviceType]
    public let moduleTemplates: [ModuleTemplate]
    public let devices: [Device]
    public let modules: [Module]
    public let rackPlacements: [RackPlacement]
    public let ports: [NetworkModel.Port]
    public let internalLinks: [InternalLink]
    public let cables: [Cable]
    public let vrfs: [VRF]
    public let prefixes: [Prefix]
    public let addresses: [IPAddressRecord]
    public let vlanGroups: [VLANGroup]
    public let vlans: [VLAN]
    public let interfaces: [Interface]
    public let assignments: [IPAddressAssignment]
    public let floorPlanAnchors: [FloorPlanAnchor]
    public let memberships: [InterfaceVLANMembership]

    public init(
        locations: [Location] = [], racks: [Rack] = [], deviceTypes: [DeviceType] = [],
        moduleTemplates: [ModuleTemplate] = [], devices: [Device] = [], modules: [Module] = [],
        rackPlacements: [RackPlacement] = [], ports: [NetworkModel.Port] = [], internalLinks: [InternalLink] = [],
        cables: [Cable] = [], vrfs: [VRF] = [], prefixes: [Prefix] = [], addresses: [IPAddressRecord] = [],
        vlanGroups: [VLANGroup] = [], vlans: [VLAN] = [], interfaces: [Interface] = [],
        assignments: [IPAddressAssignment] = [], floorPlanAnchors: [FloorPlanAnchor] = [],
        memberships: [InterfaceVLANMembership] = []
    ) {
        self.locations = locations
        self.racks = racks
        self.deviceTypes = deviceTypes
        self.moduleTemplates = moduleTemplates
        self.devices = devices
        self.modules = modules
        self.rackPlacements = rackPlacements
        self.ports = ports
        self.internalLinks = internalLinks
        self.cables = cables
        self.vrfs = vrfs
        self.prefixes = prefixes
        self.addresses = addresses
        self.vlanGroups = vlanGroups
        self.vlans = vlans
        self.interfaces = interfaces
        self.assignments = assignments
        self.floorPlanAnchors = floorPlanAnchors
        self.memberships = memberships
    }
}

/// A bounded, schema-complete group of CSV files suitable for a platform-owned
/// save/share handoff. Each file is named exclusively through the import
/// document filename contract, so it can be imported without adaptation.
public struct CSVWorkspaceExportDocument: Hashable, Sendable {
    public let document: CSVImportDocument

    public init(document: CSVImportDocument) { self.document = document }
    public var files: [CSVImportDocument.File] { document.files }
    public func filename(for file: CSVImportDocument.File) -> String {
        CSVImportDocumentFilenames.filename(for: file.table)
    }
}

public enum CSVWorkspaceExportError: Error, Equatable, Sendable {
    case nonFiniteNumber(String)
}

/// Encodes the complete published CSV schema from typed domain values. Values
/// are constructed from the same codecs that the reconstruction path consumes.
public enum CSVWorkspaceExporter {
    public static func export(_ projection: CSVWorkspaceExportProjection) throws -> CSVWorkspaceExportDocument {
        let records = try records(from: projection)
        var files: [CSVImportDocument.File] = []
        var totalRows = 0
        var totalBytes = 0
        for table in CSVTable.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let template = CSVSchemaV2.templates[table] else {
                throw CSVImportDocumentError.missingSchema(table.rawValue)
            }
            let tableRecords = records[table, default: []]
            guard tableRecords.count <= CSVImportLimits.maximumRowsPerTable else {
                throw CSVImportError.tooManyRows(table: table.rawValue)
            }
            guard totalRows <= CSVImportLimits.maximumRowsTotal - tableRecords.count else {
                throw CSVImportError.tooManyRows(table: "export")
            }
            totalRows += tableRecords.count
            let rows =
                [template.columns]
                + tableRecords.map { record in
                    template.columns.map { record.values[$0] ?? "" }
                }
            try validate(rows: rows)
            let bytes = CSVExport.encode(rows: rows)
            guard bytes.count <= CSVImportLimits.maximumFileBytes else { throw CSVImportError.fileTooLarge }
            guard totalBytes <= CSVImportLimits.maximumImportBytes - bytes.count else {
                throw CSVImportError.importTooLarge
            }
            totalBytes += bytes.count
            files.append(try CSVImportDocument.File(table: table, bytes: bytes))
        }
        return CSVWorkspaceExportDocument(document: try CSVImportDocument(files: files))
    }

    private static func records(from projection: CSVWorkspaceExportProjection) throws -> [CSVTable: [ImportRecord]] {
        [
            .locations: try projection.locations.sorted(by: idLess).map(locationRecord),
            .racks: try projection.racks.sorted(by: idLess).map(rackRecord),
            .deviceTypes: try projection.deviceTypes.sorted(by: idLess).map(deviceTypeRecord),
            .moduleTemplates: try projection.moduleTemplates.sorted(by: idLess).map(moduleTemplateRecord),
            .devices: try projection.devices.sorted(by: idLess).map(deviceRecord),
            .modules: try projection.modules.sorted(by: idLess).map(moduleRecord),
            .rackPlacements: projection.rackPlacements.sorted { $0.deviceID < $1.deviceID }.map(rackPlacementRecord),
            .ports: try projection.ports.sorted(by: idLess).map(portRecord),
            .internalLinks: projection.internalLinks.sorted(by: idLess).map(internalLinkRecord),
            .cables: try projection.cables.sorted(by: idLess).map(cableRecord),
            .vrfs: projection.vrfs.sorted(by: idLess).map(vrfRecord),
            .prefixes: try projection.prefixes.sorted(by: idLess).map(prefixRecord),
            .addresses: projection.addresses.sorted { $0.id < $1.id }.map(addressRecord),
            .vlanGroups: projection.vlanGroups.sorted(by: idLess).map(vlanGroupRecord),
            .vlans: projection.vlans.sorted(by: idLess).map(vlanRecord),
            .interfaces: projection.interfaces.sorted(by: idLess).map(interfaceRecord),
            .assignments: projection.assignments.sorted(by: idLess).map(assignmentRecord),
            .floorPlanAnchors: try projection.floorPlanAnchors.sorted(by: idLess).map(floorPlanAnchorRecord),
            .memberships: projection.memberships.sorted(by: idLess).map(membershipRecord),
        ]
    }

    private static func locationRecord(_ value: Location) throws -> ImportRecord {
        record(
            .locations,
            ["id": id(value.id), "name": value.name, "kind": value.kind.rawValue, "parentID": optionalID(value.parentID), "deletedAt": date(value.deletedAt)])
    }
    private static func rackRecord(_ value: Rack) throws -> ImportRecord {
        record(
            .racks,
            [
                "id": id(value.id), "assetCode": value.assetCode.value, "locationID": id(value.locationID), "heightRU": String(value.heightRU),
                "deletedAt": date(value.deletedAt),
            ])
    }
    private static func deviceTypeRecord(_ value: DeviceType) throws -> ImportRecord {
        record(
            .deviceTypes,
            [
                "id": id(value.id), "name": value.name, "kind": value.kind.rawValue, "customFieldsJSON": try json(value.customFields),
                "version": String(value.version),
                "rackHeightRU": String(value.rackHeightRU), "portTemplatesJSON": try json(value.portTemplates), "moduleSlotsJSON": try json(value.moduleSlots),
                "customFieldSchemasJSON": try json(value.customFieldSchemas),
            ])
    }
    private static func moduleTemplateRecord(_ value: ModuleTemplate) throws -> ImportRecord {
        record(
            .moduleTemplates,
            [
                "id": id(value.id), "name": value.name, "portsJSON": try json(value.ports), "version": String(value.version),
                "customFieldSchemasJSON": try json(value.customFieldSchemas),
            ])
    }
    private static func deviceRecord(_ value: Device) throws -> ImportRecord {
        record(
            .devices,
            [
                "id": id(value.id), "assetCode": value.assetCode.value, "name": value.name, "typeID": id(value.typeID), "rackID": optionalID(value.rackID),
                "customFieldsJSON": try json(value.customFields),
                "templateSnapshotJSON": try optionalJSON(value.templateSnapshot),
            ])
    }
    private static func moduleRecord(_ value: Module) throws -> ImportRecord {
        record(
            .modules,
            [
                "id": id(value.id), "deviceID": id(value.deviceID), "templateID": id(value.templateID), "slot": value.slot,
                "templateSnapshotJSON": try optionalJSON(value.templateSnapshot),
                "customFieldsJSON": try json(value.customFields),
            ])
    }
    private static func rackPlacementRecord(_ value: RackPlacement) -> ImportRecord {
        record(
            .rackPlacements,
            [
                "deviceID": id(value.deviceID), "rackID": id(value.rackID), "startRU": String(value.startRU), "heightRU": String(value.heightRU),
                "face": value.face.rawValue,
            ])
    }
    private static func portRecord(_ value: NetworkModel.Port) throws -> ImportRecord {
        record(
            .ports,
            [
                "id": id(value.id), "deviceID": id(value.deviceID), "moduleID": optionalID(value.moduleID), "templatePortID": optionalID(value.templatePortID),
                "label": value.label,
                "medium": value.medium.rawValue, "connector": value.connector.rawValue, "face": value.face.rawValue,
                "fiberMode": value.fiberMode?.rawValue ?? "", "availability": value.availability.rawValue,
                "customFieldsJSON": try json(value.customFields),
            ])
    }
    private static func internalLinkRecord(_ value: InternalLink) -> ImportRecord {
        record(.internalLinks, ["id": id(value.id), "endpointA": id(value.endpointA), "endpointB": id(value.endpointB), "kind": ""])
    }
    private static func cableRecord(_ value: Cable) throws -> ImportRecord {
        record(
            .cables,
            [
                "id": id(value.id), "assetCode": value.assetCode.value, "endpointA": id(value.endpointA), "connectorA": value.connectorA.rawValue,
                "endpointB": id(value.endpointB),
                "connectorB": value.connectorB.rawValue, "medium": value.medium.rawValue, "kind": value.kind.rawValue, "status": value.status.rawValue,
                "color": value.color ?? "", "lengthMeters": try value.lengthMeters.map(number) ?? "",
            ])
    }
    private static func vrfRecord(_ value: VRF) -> ImportRecord {
        record(
            .vrfs,
            [
                "id": id(value.id), "name": value.name, "revision": String(value.revision), "state": value.state.rawValue,
                "tombstonedAt": date(value.tombstonedAt),
            ])
    }
    private static func prefixRecord(_ value: Prefix) throws -> ImportRecord {
        record(
            .prefixes,
            [
                "id": id(value.id), "vrfID": id(value.vrfID), "cidr": value.cidr, "name": value.name, "reservedRangesJSON": try json(value.reservedRanges),
                "state": value.state.rawValue, "tombstonedAt": date(value.tombstonedAt),
            ])
    }
    private static func addressRecord(_ value: IPAddressRecord) -> ImportRecord {
        record(
            .addresses,
            [
                "id": value.id, "vrfID": id(value.vrfID), "address": value.address.description, "assignedInterfaceID": optionalID(value.assignedInterfaceID),
                "state": value.state.rawValue,
                "tombstonedAt": date(value.tombstonedAt),
            ])
    }
    private static func vlanGroupRecord(_ value: VLANGroup) -> ImportRecord {
        record(.vlanGroups, ["id": id(value.id), "name": value.name, "state": value.state.rawValue, "tombstonedAt": date(value.tombstonedAt)])
    }
    private static func vlanRecord(_ value: VLAN) -> ImportRecord {
        record(
            .vlans,
            [
                "id": id(value.id), "groupID": id(value.groupID), "number": String(value.number), "name": value.name, "state": value.state.rawValue,
                "tombstonedAt": date(value.tombstonedAt),
            ])
    }
    private static func interfaceRecord(_ value: Interface) -> ImportRecord {
        record(
            .interfaces,
            [
                "id": id(value.id), "deviceID": id(value.deviceID), "physicalPortID": optionalID(value.physicalPortID), "name": value.name,
                "mode": value.mode.rawValue, "kind": value.kind.rawValue,
                "vlanID": optionalID(value.vlanID), "state": value.state.rawValue, "tombstonedAt": date(value.tombstonedAt),
            ])
    }
    private static func assignmentRecord(_ value: IPAddressAssignment) -> ImportRecord {
        record(
            .assignments,
            [
                "id": id(value.id), "addressID": value.addressID, "interfaceID": id(value.interfaceID), "isPrimary": value.isPrimary ? "true" : "false",
                "state": value.state.rawValue, "tombstonedAt": date(value.tombstonedAt),
            ])
    }
    private static func floorPlanAnchorRecord(_ value: FloorPlanAnchor) throws -> ImportRecord {
        record(
            .floorPlanAnchors,
            ["id": id(value.id), "objectID": id(value.objectID), "floorID": id(value.floorID), "x": try number(value.x), "y": try number(value.y)])
    }
    private static func membershipRecord(_ value: InterfaceVLANMembership) -> ImportRecord {
        record(
            .memberships,
            [
                "id": id(value.id), "interfaceID": id(value.interfaceID), "vlanID": id(value.vlanID), "isNative": value.isNative ? "true" : "false",
                "state": value.state.rawValue, "tombstonedAt": date(value.tombstonedAt),
            ])
    }

    private static func record(_ table: CSVTable, _ values: [String: String]) -> ImportRecord {
        ImportRecord(table: table.rawValue, values: values)
    }
    private static func validate(rows: [[String]]) throws {
        for row in rows {
            for value in row {
                guard Data(CSVExport.escapedCell(value).utf8).count <= CSVImportLimits.maximumCellBytes else {
                    throw CSVImportError.cellTooLarge
                }
            }
            let encodedRow = CSVExport.encode(rows: [row])
            guard encodedRow.count >= 2, encodedRow.count - 2 <= CSVImportLimits.maximumRowBytes else {
                throw CSVImportError.rowTooLarge
            }
        }
    }
    private static func id(_ value: ObjectID) -> String { value.description }
    private static func optionalID(_ value: ObjectID?) -> String { value.map(id) ?? "" }
    private static func date(_ value: Date?) -> String { value.map { ISO8601DateFormatter().string(from: $0) } ?? "" }
    private static func number(_ value: Double) throws -> String {
        guard value.isFinite else { throw CSVWorkspaceExportError.nonFiniteNumber(String(value)) }
        return String(value)
    }
    private static func json<T: Encodable>(_ value: T) throws -> String { String(decoding: try WorkspaceTransferCoding.encode(value), as: UTF8.self) }
    private static func optionalJSON<T: Encodable>(_ value: T?) throws -> String {
        guard let value else { return "" }
        return try json(value)
    }
    private static func idLess<T: Identifiable>(_ lhs: T, _ rhs: T) -> Bool where T.ID == ObjectID { lhs.id < rhs.id }
}
