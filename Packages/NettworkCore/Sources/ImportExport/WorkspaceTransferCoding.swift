import CryptoKit
import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum WorkspaceTransferRecordError: Error, Equatable, Sendable {
    case unknownTable(String)
    case invalidColumns(table: String)
    case missingField(table: String, field: String)
    case invalidUUID(table: String, field: String, value: String)
    case invalidEnum(table: String, field: String, value: String)
    case invalidInteger(table: String, field: String, value: String)
    case invalidNumber(table: String, field: String, value: String)
    case invalidBoolean(table: String, field: String, value: String)
    case invalidDate(table: String, field: String, value: String)
    case invalidJSON(table: String, field: String)
    case invalidAddress(table: String, field: String, value: String)
    case nonCanonicalAddressID(expected: String, actual: String)
    case nonCanonicalPrefix(table: String, field: String, value: String)
    case missingTombstoneDate(table: String, field: String)
    case unexpectedTombstoneDate(table: String, field: String)
    case unsupportedPublishedColumn(table: String, field: String)
    case unsupportedSchemaVersion(Int)
    case rowTooLarge
    case transferTooLarge
    case tooManyRows
    case malformedJSONL
    case nonCanonicalJSONL
    case duplicateResource(ResourceKey)
}

public enum WorkspaceTransferCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try CanonicalJSONCoding.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try CanonicalJSONCoding.decode(type, from: data)
    }
}

/// Canonical JSONL is sorted by type and resource identity and has exactly one
/// LF after each row. Decoding requires that same form, preventing duplicate
/// JSON members and alternate wire representations from reaching validation.
public enum WorkspaceTransferJSONL {
    public static func encode(_ records: [WorkspaceTransferRecord]) throws -> Data {
        try validateBounds(records)
        let rows = try records.sorted(by: sort).map { try WorkspaceTransferCoding.encode($0) }
        return rows.reduce(into: Data()) { result, row in
            result.append(row)
            result.append(0x0A)
        }
    }

    public static func decode(_ data: Data) throws -> [WorkspaceTransferRecord] {
        guard data.count <= WorkspaceTransferLimits.maximumBytes else { throw WorkspaceTransferRecordError.transferTooLarge }
        guard !data.isEmpty else { return [] }
        guard data.last == 0x0A else { throw WorkspaceTransferRecordError.nonCanonicalJSONL }

        let rows = data.dropLast().split(separator: 0x0A, omittingEmptySubsequences: false)
        guard rows.count <= WorkspaceTransferLimits.maximumRows else { throw WorkspaceTransferRecordError.tooManyRows }
        var records: [WorkspaceTransferRecord] = []
        var keys = Set<ResourceKey>()
        for row in rows {
            records.append(try decodeRow(row, insertingInto: &keys))
        }
        return records
    }

    private static func decodeRow(
        _ row: Data.SubSequence, insertingInto keys: inout Set<ResourceKey>
    ) throws -> WorkspaceTransferRecord {
        guard !row.isEmpty else { throw WorkspaceTransferRecordError.malformedJSONL }
        guard row.count <= WorkspaceTransferLimits.maximumRowBytes else {
            throw WorkspaceTransferRecordError.rowTooLarge
        }
        let data = Data(row)
        let record: WorkspaceTransferRecord
        do {
            record = try WorkspaceTransferCoding.decode(WorkspaceTransferRecord.self, from: data)
        } catch {
            throw WorkspaceTransferRecordError.malformedJSONL
        }
        guard record.schemaVersion == WorkspaceTransferRecord.currentSchemaVersion else {
            throw WorkspaceTransferRecordError.unsupportedSchemaVersion(record.schemaVersion)
        }
        guard try WorkspaceTransferCoding.encode(record) == data else {
            throw WorkspaceTransferRecordError.nonCanonicalJSONL
        }
        guard keys.insert(record.resourceKey).inserted else {
            throw WorkspaceTransferRecordError.duplicateResource(record.resourceKey)
        }
        return record
    }

    private static func validateBounds(_ records: [WorkspaceTransferRecord]) throws {
        guard records.count <= WorkspaceTransferLimits.maximumRows else { throw WorkspaceTransferRecordError.tooManyRows }
        var keys = Set<ResourceKey>()
        var totalBytes = 0
        for record in records {
            guard record.schemaVersion == WorkspaceTransferRecord.currentSchemaVersion else {
                throw WorkspaceTransferRecordError.unsupportedSchemaVersion(record.schemaVersion)
            }
            guard keys.insert(record.resourceKey).inserted else {
                throw WorkspaceTransferRecordError.duplicateResource(record.resourceKey)
            }
            let rowBytes = try WorkspaceTransferCoding.encode(record).count
            guard rowBytes <= WorkspaceTransferLimits.maximumRowBytes else {
                throw WorkspaceTransferRecordError.rowTooLarge
            }
            guard totalBytes <= WorkspaceTransferLimits.maximumBytes - rowBytes - 1 else {
                throw WorkspaceTransferRecordError.transferTooLarge
            }
            totalBytes += rowBytes + 1
        }
    }

    private static func sort(_ lhs: WorkspaceTransferRecord, _ rhs: WorkspaceTransferRecord) -> Bool {
        if lhs.recordType != rhs.recordType { return lhs.recordType.rawValue < rhs.recordType.rawValue }
        return lhs.resourceKey < rhs.resourceKey
    }
}
