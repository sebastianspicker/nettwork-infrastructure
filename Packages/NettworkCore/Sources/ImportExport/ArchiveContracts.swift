import ContentSafety
import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum CSVTable: String, Codable, CaseIterable, Sendable {
    case locations, racks
    case deviceTypes = "device_types"
    case moduleTemplates = "module_templates"
    case devices, modules
    case rackPlacements = "rack_placements"
    case ports
    case internalLinks = "internal_links"
    case cables, vrfs, prefixes, addresses
    case vlanGroups = "vlan_groups"
    case vlans, interfaces
    case assignments = "ip_address_assignments"
    case floorPlanAnchors = "floor_plan_anchors"
    case memberships
}

/// A CSV schema is deliberately exact: callers publish the v1 column order.
public struct CSVTemplate: Codable, Hashable, Sendable {
    public let table: CSVTable
    public let version: Int
    public let columns: [String]
    public let compatibleColumns: [[String]]?

    public init(table: CSVTable, version: Int = 1, columns: [String], compatibleColumns: [[String]] = []) {
        self.table = table
        self.version = version
        self.columns = columns
        self.compatibleColumns = compatibleColumns.isEmpty ? nil : compatibleColumns
    }

    public func validates(header: [String]) throws {
        guard (1...2).contains(version) else { throw CSVImportError.unsupportedSchemaVersion(version) }
        guard columns.count <= CSVImportLimits.maximumColumns else { throw CSVImportError.tooManyColumns }
        guard Set(columns).count == columns.count else { throw CSVImportError.duplicateHeader }
        guard header == columns || (compatibleColumns ?? []).contains(header) else {
            throw CSVImportError.unexpectedHeader(expected: columns, actual: header)
        }
    }

    public func validates(columnNames: Set<String>) -> Bool {
        columnNames == Set(columns) || (compatibleColumns ?? []).contains { columnNames == Set($0) }
    }
}

/// Published v1 headers. Empty optional values remain cells, which keeps every
/// exported file round-trippable and makes unknown/reordered columns fail fast.
public enum CSVSchemaV1 {
    public static let templates: [CSVTable: CSVTemplate] = [
        .locations: .init(table: .locations, columns: ["id", "name", "kind", "parentID", "deletedAt"]),
        .racks: .init(table: .racks, columns: ["id", "assetCode", "locationID", "heightRU", "deletedAt"]),
        .deviceTypes: .init(
            table: .deviceTypes,
            columns: ["id", "name", "kind", "customFieldsJSON", "version", "rackHeightRU", "portTemplatesJSON", "moduleSlotsJSON", "customFieldSchemasJSON"]),
        .moduleTemplates: .init(table: .moduleTemplates, columns: ["id", "name", "portsJSON", "version", "customFieldSchemasJSON"]),
        .devices: .init(table: .devices, columns: ["id", "assetCode", "name", "typeID", "rackID", "customFieldsJSON", "templateSnapshotJSON"]),
        .modules: .init(table: .modules, columns: ["id", "deviceID", "templateID", "slot", "templateSnapshotJSON", "customFieldsJSON"]),
        .rackPlacements: .init(table: .rackPlacements, columns: ["deviceID", "rackID", "startRU", "heightRU", "face"]),
        .ports: .init(
            table: .ports, columns: ["id", "deviceID", "moduleID", "label", "medium", "connector", "face", "fiberMode", "availability", "customFieldsJSON"]),
        .internalLinks: .init(table: .internalLinks, columns: ["id", "endpointA", "endpointB", "kind"]),
        .cables: .init(
            table: .cables,
            columns: ["id", "assetCode", "endpointA", "connectorA", "endpointB", "connectorB", "medium", "kind", "status", "color", "lengthMeters"]),
        .vrfs: .init(table: .vrfs, columns: ["id", "name", "revision", "state", "tombstonedAt"]),
        .prefixes: .init(table: .prefixes, columns: ["id", "vrfID", "cidr", "name", "reservedRangesJSON", "state", "tombstonedAt"]),
        .addresses: .init(table: .addresses, columns: ["id", "vrfID", "address", "assignedInterfaceID", "state", "tombstonedAt"]),
        .vlanGroups: .init(table: .vlanGroups, columns: ["id", "name", "state", "tombstonedAt"]),
        .vlans: .init(table: .vlans, columns: ["id", "groupID", "number", "name", "state", "tombstonedAt"]),
        .interfaces: .init(table: .interfaces, columns: ["id", "deviceID", "physicalPortID", "name", "mode", "kind", "vlanID", "state", "tombstonedAt"]),
        .assignments: .init(table: .assignments, columns: ["id", "addressID", "interfaceID", "isPrimary", "state", "tombstonedAt"]),
        .floorPlanAnchors: .init(table: .floorPlanAnchors, columns: ["id", "objectID", "floorID", "x", "y"]),
        .memberships: .init(table: .memberships, columns: ["id", "interfaceID", "vlanID", "isNative", "state", "tombstonedAt"]),
    ]
}

/// Current additive schema. A v1 port table is still accepted, but its missing
/// template identity decodes as nil and is deliberately not migratable until
/// reconciled. New exports always include the stable template-port identity.
public enum CSVSchemaV2 {
    public static let templates: [CSVTable: CSVTemplate] = Dictionary(
        uniqueKeysWithValues: CSVTable.allCases.map { table -> (CSVTable, CSVTemplate) in
            guard let legacy = CSVSchemaV1.templates[table] else {
                preconditionFailure("Every supported CSV v2 table must have a v1 template.")
            }
            if table == .ports {
                return (
                    table,
                    CSVTemplate(
                        table: table, version: 2,
                        columns: [
                            "id", "deviceID", "moduleID", "templatePortID", "label", "medium", "connector", "face", "fiberMode", "availability",
                            "customFieldsJSON",
                        ],
                        compatibleColumns: [legacy.columns])
                )
            }
            return (table, CSVTemplate(table: table, version: 2, columns: legacy.columns))
        })
}

public enum CSVImportLimits {
    public static let maximumFileBytes = 64 * 1024 * 1024
    public static let maximumImportBytes = 256 * 1024 * 1024
    public static let maximumRowsPerTable = 100_000
    public static let maximumRowsTotal = 250_000
    public static let maximumColumns = 128
    public static let maximumCellBytes = 64 * 1024
    public static let maximumRowBytes = 1024 * 1024
}

public enum CSVImportError: Error, Equatable, Sendable {
    case fileTooLarge, importTooLarge, malformedUTF8, nulByte, bareCarriageReturn, bareLineFeed
    case unterminatedQuotedField, invalidQuotePlacement, tooManyColumns, cellTooLarge, rowTooLarge, duplicateHeader
    case unexpectedHeader(expected: [String], actual: [String])
    case unsupportedSchemaVersion(Int)
    case rowColumnCount(expected: Int, actual: Int)
    case tooManyRows(table: String)
    case duplicateTable(String)
}

public enum CSVExport {
    /// Prefix before leading invisible characters so trimming cannot reactivate
    /// a formula. A literal leading apostrophe is doubled, making the escape
    /// exactly reversible by `decodedCell`.
    public static func escapedCell(_ value: String) -> String {
        if value.first == "'" { return "'" + value }
        let candidate = value.drop(while: isLeadingInvisible)
        guard let first = candidate.first, "=+-@".contains(first) else { return value }
        return "'" + value
    }

    public static func decodedCell(_ value: String) -> String {
        guard value.first == "'" else { return value }
        let remainder = String(value.dropFirst())
        if remainder.first == "'" { return remainder }
        let candidate = remainder.drop(while: isLeadingInvisible)
        guard let first = candidate.first, "=+-@".contains(first) else { return value }
        return remainder
    }

    public static func encode(rows: [[String]]) -> Data {
        let body = rows.map { $0.map(encodeCell).joined(separator: ",") }.joined(separator: "\r\n")
        return Data((body.isEmpty ? body : body + "\r\n").utf8)
    }

    private static func isLeadingInvisible(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }
    }

    private static func encodeCell(_ raw: String) -> String {
        let value = escapedCell(raw)
        guard value.contains(",") || value.contains("\"") || value.contains("\r") || value.contains("\n") else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
