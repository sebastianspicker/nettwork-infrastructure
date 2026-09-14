import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum WorkspaceTransferRecordReconstruction {
    public static func records(from imports: [ImportRecord]) throws -> [WorkspaceTransferRecord] {
        guard imports.count <= WorkspaceTransferLimits.maximumRows else { throw WorkspaceTransferRecordError.tooManyRows }
        let records = try imports.map(record(from:))
        _ = try WorkspaceTransferJSONL.encode(records)
        return records
    }

    public static func record(from source: ImportRecord) throws -> WorkspaceTransferRecord {
        guard let table = CSVTable(rawValue: source.table), let template = CSVSchemaV2.templates[table] else {
            throw WorkspaceTransferRecordError.unknownTable(source.table)
        }
        guard template.validates(columnNames: Set(source.values.keys)) else {
            throw WorkspaceTransferRecordError.invalidColumns(table: source.table)
        }

        switch table {
        case .locations, .racks, .deviceTypes, .moduleTemplates, .devices, .modules, .rackPlacements:
            return try infrastructureRecord(table: table, source: source)
        case .ports, .internalLinks, .cables:
            return try topologyRecord(table: table, source: source)
        case .vrfs, .prefixes, .addresses, .vlans, .vlanGroups:
            return try ipamRecord(table: table, source: source)
        case .interfaces, .assignments, .floorPlanAnchors, .memberships:
            return try logicalRecord(table: table, source: source)
        }
    }

    private static func infrastructureRecord(
        table: CSVTable, source: ImportRecord
    ) throws -> WorkspaceTransferRecord {
        switch table {
        case .locations:
            let id = try objectID(source, "id")
            let deletedAt = try optionalDate(source, "deletedAt")
            let value = Location(
                id: id, name: try required(source, "name"), kind: try enumValue(LocationKind.self, source, "kind"),
                parentID: try optionalObjectID(source, "parentID"), deletedAt: deletedAt)
            return try envelope(value, key: .object(id), type: .location, tombstone: deletedAt)
        case .racks:
            let id = try objectID(source, "id")
            let deletedAt = try optionalDate(source, "deletedAt")
            let value = Rack(
                id: id, assetCode: AssetCode(try required(source, "assetCode")), locationID: try objectID(source, "locationID"),
                heightRU: try integer(source, "heightRU"), deletedAt: deletedAt)
            return try envelope(value, key: .object(id), type: .rack, tombstone: deletedAt)
        case .deviceTypes:
            let id = try objectID(source, "id")
            let value = DeviceType(
                id: id, name: try required(source, "name"), kind: try enumValue(DeviceKind.self, source, "kind"),
                customFields: try json([CustomFieldValue].self, source, "customFieldsJSON"),
                version: try integer(source, "version"), rackHeightRU: try integer(source, "rackHeightRU"),
                portTemplates: try json([PortTemplate].self, source, "portTemplatesJSON"),
                moduleSlots: try json([ModuleSlotTemplate].self, source, "moduleSlotsJSON"),
                customFieldSchemas: try json([CustomFieldSchema].self, source, "customFieldSchemasJSON"))
            return try envelope(value, key: .object(id), type: .deviceType)
        case .moduleTemplates:
            let id = try objectID(source, "id")
            let value = ModuleTemplate(
                id: id, name: try required(source, "name"),
                ports: try json([PortTemplate].self, source, "portsJSON"),
                version: try integer(source, "version"),
                customFieldSchemas: try json([CustomFieldSchema].self, source, "customFieldSchemasJSON"))
            return try envelope(value, key: .object(id), type: .moduleTemplate)
        case .devices:
            let id = try objectID(source, "id")
            let value = Device(
                id: id, assetCode: AssetCode(try required(source, "assetCode")), name: try required(source, "name"), typeID: try objectID(source, "typeID"),
                rackID: try optionalObjectID(source, "rackID"),
                customFields: try json([CustomFieldValue].self, source, "customFieldsJSON"),
                templateSnapshot: try optionalJSON(DeviceTemplateSnapshot.self, source, "templateSnapshotJSON"))
            return try envelope(value, key: .object(id), type: .device)
        case .modules:
            let id = try objectID(source, "id")
            let value = Module(
                id: id, deviceID: try objectID(source, "deviceID"),
                templateID: try objectID(source, "templateID"), slot: try required(source, "slot"),
                templateSnapshot: try optionalJSON(ModuleTemplateSnapshot.self, source, "templateSnapshotJSON"),
                customFields: try json([CustomFieldValue].self, source, "customFieldsJSON"))
            return try envelope(value, key: .object(id), type: .module)
        case .rackPlacements:
            let deviceID = try objectID(source, "deviceID")
            let value = RackPlacement(
                deviceID: deviceID, rackID: try objectID(source, "rackID"),
                startRU: try integer(source, "startRU"), heightRU: try integer(source, "heightRU"),
                face: try enumValue(RackPlacement.Face.self, source, "face"))
            return try envelope(value, key: .rackPlacement(deviceID: deviceID), type: .rackPlacement)
        default: throw WorkspaceTransferRecordError.unknownTable(source.table)
        }
    }

    private static func topologyRecord(
        table: CSVTable, source: ImportRecord
    ) throws -> WorkspaceTransferRecord {
        switch table {
        case .ports:
            let id = try objectID(source, "id")
            let value = NetworkModel.Port(
                id: id, deviceID: try objectID(source, "deviceID"), moduleID: try optionalObjectID(source, "moduleID"),
                templatePortID: try optionalObjectIDIfPresent(source, "templatePortID"),
                label: try required(source, "label"), medium: try enumValue(PortMedium.self, source, "medium"),
                connector: try enumValue(Connector.self, source, "connector"),
                face: try enumValue(
                    PortFace.self, source,
                    "face"), fiberMode: try optionalEnum(FiberMode.self, source, "fiberMode"),
                availability: try enumValue(PortAvailability.self, source, "availability"),
                customFields: try json(
                    [CustomFieldValue].self,
                    source, "customFieldsJSON"))
            return try envelope(value, key: .object(id), type: .port)
        case .internalLinks:
            let kind = try required(source, "kind")
            guard kind.isEmpty else { throw WorkspaceTransferRecordError.unsupportedPublishedColumn(table: table.rawValue, field: "kind") }
            let id = try objectID(source, "id")
            let value = InternalLink(id: id, endpointA: try objectID(source, "endpointA"), endpointB: try objectID(source, "endpointB"))
            return try envelope(value, key: .object(id), type: .internalLink)
        case .cables:
            let id = try objectID(source, "id")
            let value = Cable(
                id: id, assetCode: AssetCode(try required(source, "assetCode")), endpointA: try objectID(source, "endpointA"),
                connectorA: try enumValue(Connector.self, source, "connectorA"),
                endpointB: try objectID(source, "endpointB"), connectorB: try enumValue(Connector.self, source, "connectorB"),
                medium: try enumValue(PortMedium.self, source, "medium"),
                kind: try enumValue(
                    CableKind.self,
                    source, "kind"), status: try enumValue(CableStatus.self, source, "status"), color: try optional(source, "color"),
                lengthMeters: try optionalNumber(source, "lengthMeters"))
            return try envelope(value, key: .object(id), type: .cable)
        default: throw WorkspaceTransferRecordError.unknownTable(source.table)
        }
    }

    private static func ipamRecord(
        table: CSVTable, source: ImportRecord
    ) throws -> WorkspaceTransferRecord {
        switch table {
        case .vrfs: return try vrfRecord(source, table: table)
        case .prefixes: return try prefixRecord(source, table: table)
        case .addresses: return try addressRecord(source, table: table)
        case .vlans: return try vlanRecord(source)
        case .vlanGroups: return try vlanGroupRecord(source)
        default: throw WorkspaceTransferRecordError.unknownTable(source.table)
        }
    }

    private static func vrfRecord(_ source: ImportRecord, table: CSVTable) throws -> WorkspaceTransferRecord {
        let id = try objectID(source, "id")
        let state: IPAMRecordState = try enumValue(IPAMRecordState.self, source, "state")
        let tombstonedAt = try lifecycleDate(source, "tombstonedAt", state: state)
        let revision = try integer(source, "revision")
        guard revision >= 0 else {
            throw WorkspaceTransferRecordError.invalidInteger(table: table.rawValue, field: "revision", value: try required(source, "revision"))
        }
        let value = VRF(id: id, name: try required(source, "name"), revision: revision, state: state, tombstonedAt: tombstonedAt)
        return try envelope(value, key: .object(id), type: .vrf, tombstone: tombstonedAt)
    }

    private static func prefixRecord(_ source: ImportRecord, table: CSVTable) throws -> WorkspaceTransferRecord {
        let id = try objectID(source, "id"), state: IPAMRecordState = try enumValue(IPAMRecordState.self, source, "state")
        let tombstonedAt = try lifecycleDate(source, "tombstonedAt", state: state), cidr = try required(source, "cidr")
        guard
            let value = Prefix(
                id: id, vrfID: try objectID(source, "vrfID"), cidr: cidr, name: try required(source, "name"),
                reservedRanges: try json([ReservedAddressRange].self, source, "reservedRangesJSON"), state: state, tombstonedAt: tombstonedAt),
            value.cidr == cidr
        else {
            throw WorkspaceTransferRecordError.nonCanonicalPrefix(table: table.rawValue, field: "cidr", value: cidr)
        }
        return try envelope(value, key: .object(id), type: .prefix, tombstone: tombstonedAt)
    }

    private static func addressRecord(_ source: ImportRecord, table: CSVTable) throws -> WorkspaceTransferRecord {
        let vrfID = try objectID(source, "vrfID"), rawAddress = try required(source, "address")
        guard let address = IPAddress(parsing: rawAddress), address.description == rawAddress else {
            throw WorkspaceTransferRecordError.invalidAddress(table: table.rawValue, field: "address", value: rawAddress)
        }
        let state: IPAMRecordState = try enumValue(IPAMRecordState.self, source, "state")
        let tombstonedAt = try lifecycleDate(source, "tombstonedAt", state: state)
        let value = IPAddressRecord(
            vrfID: vrfID, address: address, assignedInterfaceID: try optionalObjectID(source, "assignedInterfaceID"), state: state, tombstonedAt: tombstonedAt)
        let suppliedID = try required(source, "id")
        guard suppliedID == value.id else { throw WorkspaceTransferRecordError.nonCanonicalAddressID(expected: value.id, actual: suppliedID) }
        return try envelope(value, key: .string(value.id), type: .address, tombstone: tombstonedAt)
    }

    private static func vlanRecord(_ source: ImportRecord) throws -> WorkspaceTransferRecord {
        let id = try objectID(source, "id"), state: IPAMRecordState = try enumValue(IPAMRecordState.self, source, "state")
        let tombstonedAt = try lifecycleDate(source, "tombstonedAt", state: state)
        let value = VLAN(
            id: id, groupID: try objectID(source, "groupID"), number: try integer(source, "number"), name: try required(source, "name"), state: state,
            tombstonedAt: tombstonedAt)
        return try envelope(value, key: .object(id), type: .vlan, tombstone: tombstonedAt)
    }

    private static func vlanGroupRecord(_ source: ImportRecord) throws -> WorkspaceTransferRecord {
        let id = try objectID(source, "id"), state: IPAMRecordState = try enumValue(IPAMRecordState.self, source, "state")
        let tombstonedAt = try lifecycleDate(source, "tombstonedAt", state: state)
        let value = VLANGroup(id: id, name: try required(source, "name"), state: state, tombstonedAt: tombstonedAt)
        return try envelope(value, key: .object(id), type: .vlanGroup, tombstone: tombstonedAt)
    }

    private static func logicalRecord(
        table: CSVTable, source: ImportRecord
    ) throws -> WorkspaceTransferRecord {
        switch table {
        case .interfaces:
            let id = try objectID(source, "id")
            let state: IPAMRecordState = try enumValue(IPAMRecordState.self, source, "state")
            let tombstonedAt = try lifecycleDate(source, "tombstonedAt", state: state)
            let value = Interface(
                id: id, deviceID: try objectID(source, "deviceID"), physicalPortID: try optionalObjectID(source, "physicalPortID"),
                name: try required(source, "name"),
                mode: try enumValue(InterfaceMode.self, source, "mode"), kind: try enumValue(InterfaceKind.self, source, "kind"),
                vlanID: try optionalObjectID(source, "vlanID"), state: state, tombstonedAt: tombstonedAt)
            return try envelope(value, key: .object(id), type: .interface, tombstone: tombstonedAt)
        case .assignments:
            let id = try objectID(source, "id")
            let state: IPAMRecordState = try enumValue(IPAMRecordState.self, source, "state")
            let tombstonedAt = try lifecycleDate(source, "tombstonedAt", state: state)
            let value = IPAddressAssignment(
                id: id, addressID: try required(source, "addressID"),
                interfaceID: try objectID(source, "interfaceID"), isPrimary: try boolean(source, "isPrimary"),
                state: state, tombstonedAt: tombstonedAt)
            return try envelope(value, key: .object(id), type: .assignment, tombstone: tombstonedAt)
        case .floorPlanAnchors:
            let id = try objectID(source, "id")
            let value = FloorPlanAnchor(
                id: id, objectID: try objectID(source, "objectID"), floorID: try objectID(source, "floorID"), x: try number(source, "x"),
                y: try number(source, "y"))
            return try envelope(value, key: .object(id), type: .floorPlanAnchor)
        case .memberships:
            let id = try objectID(source, "id")
            let state: IPAMRecordState = try enumValue(IPAMRecordState.self, source, "state")
            let tombstonedAt = try lifecycleDate(source, "tombstonedAt", state: state)
            let value = InterfaceVLANMembership(
                id: id, interfaceID: try objectID(source, "interfaceID"), vlanID: try objectID(source, "vlanID"), isNative: try boolean(source, "isNative"),
                state: state, tombstonedAt: tombstonedAt)
            return try envelope(value, key: .object(id), type: .membership, tombstone: tombstonedAt)
        default: throw WorkspaceTransferRecordError.unknownTable(source.table)
        }
    }

    private static func envelope<T: Encodable>(_ value: T, key: ResourceKey, type: WorkspaceTransferRecordType, tombstone: Date? = nil) throws
        -> WorkspaceTransferRecord
    {
        WorkspaceTransferRecord(
            resourceKey: key, recordType: type,
            payload: try WorkspaceTransferCoding.encode(value),
            tombstone: tombstone.map { WorkspaceTransferTombstone(deletedAt: $0) })
    }

    private static func required(_ record: ImportRecord, _ field: String) throws -> String {
        guard let value = record.values[field] else { throw WorkspaceTransferRecordError.missingField(table: record.table, field: field) }
        return value
    }

    private static func optional(_ record: ImportRecord, _ field: String) throws -> String? {
        let value = try required(record, field)
        return value.isEmpty ? nil : value
    }

    private static func objectID(_ record: ImportRecord, _ field: String) throws -> ObjectID {
        let value = try required(record, field)
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
            throw WorkspaceTransferRecordError.invalidUUID(table: record.table, field: field, value: value)
        }
        return ObjectID(uuid)
    }

    private static func optionalObjectID(_ record: ImportRecord, _ field: String) throws -> ObjectID? {
        guard let value = try optional(record, field) else { return nil }
        guard let uuid = UUID(uuidString: value), uuid.uuidString.lowercased() == value else {
            throw WorkspaceTransferRecordError.invalidUUID(table: record.table, field: field, value: value)
        }
        return ObjectID(uuid)
    }

    private static func optionalObjectIDIfPresent(_ record: ImportRecord, _ field: String) throws -> ObjectID? {
        guard record.values[field] != nil else { return nil }
        return try optionalObjectID(record, field)
    }

    private static func enumValue<T: RawRepresentable>(_ type: T.Type, _ record: ImportRecord, _ field: String) throws -> T where T.RawValue == String {
        let value = try required(record, field)
        guard let result = T(rawValue: value) else { throw WorkspaceTransferRecordError.invalidEnum(table: record.table, field: field, value: value) }
        return result
    }

    private static func optionalEnum<T: RawRepresentable>(_ type: T.Type, _ record: ImportRecord, _ field: String) throws -> T? where T.RawValue == String {
        guard let value = try optional(record, field) else { return nil }
        guard let result = T(rawValue: value) else { throw WorkspaceTransferRecordError.invalidEnum(table: record.table, field: field, value: value) }
        return result
    }

    private static func integer(_ record: ImportRecord, _ field: String) throws -> Int {
        let value = try required(record, field)
        guard let result = Int(value), String(result) == value else {
            throw WorkspaceTransferRecordError.invalidInteger(table: record.table, field: field, value: value)
        }
        return result
    }

    private static func number(_ record: ImportRecord, _ field: String) throws -> Double {
        let value = try required(record, field)
        guard let result = Double(value), result.isFinite else {
            throw WorkspaceTransferRecordError.invalidNumber(table: record.table, field: field, value: value)
        }
        return result
    }

    private static func optionalNumber(_ record: ImportRecord, _ field: String) throws -> Double? {
        guard let value = try optional(record, field) else { return nil }
        guard let result = Double(value), result.isFinite else {
            throw WorkspaceTransferRecordError.invalidNumber(table: record.table, field: field, value: value)
        }
        return result
    }

    private static func boolean(_ record: ImportRecord, _ field: String) throws -> Bool {
        switch try required(record, field) {
        case "true": return true
        case "false": return false
        default: throw WorkspaceTransferRecordError.invalidBoolean(table: record.table, field: field, value: try required(record, field))
        }
    }

    private static func optionalDate(_ record: ImportRecord, _ field: String) throws -> Date? {
        guard let value = try optional(record, field) else { return nil }
        guard let result = ISO8601DateFormatter().date(from: value) else {
            throw WorkspaceTransferRecordError.invalidDate(table: record.table, field: field, value: value)
        }
        return result
    }

    private static func lifecycleDate(_ record: ImportRecord, _ field: String, state: IPAMRecordState) throws -> Date? {
        let value = try optionalDate(record, field)
        if state == .tombstoned, value == nil { throw WorkspaceTransferRecordError.missingTombstoneDate(table: record.table, field: field) }
        if state == .active, value != nil { throw WorkspaceTransferRecordError.unexpectedTombstoneDate(table: record.table, field: field) }
        return value
    }

    private static func json<T: Decodable>(_ type: T.Type, _ record: ImportRecord, _ field: String) throws -> T {
        let value = try required(record, field)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { throw WorkspaceTransferRecordError.missingField(table: record.table, field: field) }
        do { return try WorkspaceTransferCoding.decode(T.self, from: data) } catch {
            throw WorkspaceTransferRecordError.invalidJSON(table: record.table, field: field)
        }
    }

    private static func optionalJSON<T: Decodable>(_ type: T.Type, _ record: ImportRecord, _ field: String) throws -> T? {
        guard let value = try optional(record, field) else { return nil }
        guard let data = value.data(using: .utf8) else { throw WorkspaceTransferRecordError.invalidJSON(table: record.table, field: field) }
        do { return try WorkspaceTransferCoding.decode(T.self, from: data) } catch {
            throw WorkspaceTransferRecordError.invalidJSON(table: record.table, field: field)
        }
    }
}
