import CryptoKit
import Foundation
import NetworkModel

public enum WorkOrderKind: String, Codable, Sendable {
    case connect, disconnect, move, device, hierarchy, ipam, vlan, floorPlan
}

public enum WorkOrderStatus: String, Codable, CaseIterable, Sendable {
    case draft, reserved, approved, executing, completed, cancellationRequested, cancelled, reconciliation
}

/// A digest supplied by a trusted caller or service. The domain deliberately
/// validates and carries digest material; it does not implement cryptography.
public struct IntentDigest: Codable, Hashable, Sendable {
    public enum Algorithm: String, Codable, Sendable { case sha256, sha384, sha512, externallyDefined }
    public let algorithm: Algorithm
    public let bytes: [UInt8]

    public init(algorithm: Algorithm, bytes: [UInt8]) throws {
        let validLength: Bool
        switch algorithm {
        case .sha256: validLength = bytes.count == 32
        case .sha384: validLength = bytes.count == 48
        case .sha512: validLength = bytes.count == 64
        case .externallyDefined: validLength = (16...1_024).contains(bytes.count)
        }
        guard validLength else { throw IntentDigestError.invalidLength(algorithm: algorithm, actual: bytes.count) }
        self.algorithm = algorithm
        self.bytes = bytes
    }

    /// Canonical lowercase hexadecimal, suitable for exact comparisons and logs.
    public var hexadecimalString: String { bytes.map { String(format: "%02x", $0) }.joined() }
}

public enum IntentDigestError: Error, Hashable, Sendable {
    case invalidLength(algorithm: IntentDigest.Algorithm, actual: Int)
    case invalidSchemaVersion(Int)
}

/// The one versioned intent representation hashed at reservation and execution.
public struct CanonicalWorkIntent: Hashable, Sendable {
    public static let schemaVersion = 2
    public let intentSchemaVersion: Int
    public let workOrderID: ObjectID
    public let kind: WorkOrderKind
    public let creatorID: String
    public let ticket: String?
    public let notes: String?
    public let operations: [PlannedWorkOperation]
    public let resourceKeys: Set<ResourceKey>
    public let evidenceHashes: [EvidenceHash]

    public init(
        intentSchemaVersion: Int = Self.schemaVersion, workOrderID: ObjectID, kind: WorkOrderKind, creatorID: String, ticket: String?, notes: String?,
        operations: [PlannedWorkOperation],
        resourceKeys: Set<ResourceKey>, evidenceHashes: [EvidenceHash]
    ) {
        self.intentSchemaVersion = intentSchemaVersion
        self.workOrderID = workOrderID
        self.kind = kind
        self.creatorID = creatorID
        self.ticket = ticket
        self.notes = notes
        self.operations = operations
        self.resourceKeys = resourceKeys
        self.evidenceHashes = evidenceHashes
    }

    public func digest() throws -> IntentDigest {
        guard (1...Self.schemaVersion).contains(intentSchemaVersion) else {
            throw IntentDigestError.invalidSchemaVersion(intentSchemaVersion)
        }
        let bytes = Array(SHA256.hash(data: try CanonicalWorkIntentEncoder.encode(self)))
        return try IntentDigest(algorithm: .sha256, bytes: bytes)
    }
}

private enum CanonicalWorkIntentEncoder {
    static func encode(_ intent: CanonicalWorkIntent) throws -> Data {
        var data = Data("nettwork.work-intent\u{0}\(intent.intentSchemaVersion)".utf8)
        append(intent.workOrderID.description, to: &data)
        append(intent.kind.rawValue, to: &data)
        append(intent.creatorID, to: &data)
        append(intent.ticket, to: &data)
        append(intent.notes, to: &data)
        append(intent.operations.count, to: &data)
        for operation in intent.operations {
            append(try operationBytes(operation, intentSchemaVersion: intent.intentSchemaVersion), to: &data)
        }
        let keys = intent.resourceKeys.map(\.description).sorted()
        append(keys.count, to: &data)
        for key in keys { append(key, to: &data) }
        let evidence = intent.evidenceHashes.sorted { lhs, rhs in
            lhs.id == rhs.id ? lhs.contentType < rhs.contentType : lhs.id < rhs.id
        }
        append(evidence.count, to: &data)
        for item in evidence {
            append(item.id.description, to: &data)
            append(item.contentType, to: &data)
            append(item.digest.algorithm.rawValue, to: &data)
            append(Data(item.digest.bytes), to: &data)
        }
        return data
    }

    private static func operationBytes(_ operation: PlannedWorkOperation, intentSchemaVersion: Int) throws -> Data {
        switch operation {
        case .topology(let command): return try encodedOperation("topology", command)
        case .deviceDecommission(let value): return try encodedOperation("device-decommission", value)
        case .ipam(let value): return try ipamBytes(value, intentSchemaVersion: intentSchemaVersion)
        case let .device(key, description): return simpleBytes("device", values: [key.description, description])
        case let .template(kind, target, source, migrations): return try templateBytes(kind: kind, target: target, source: source, migrations: migrations)
        case let .moduleTemplate(kind, target, source): return try moduleTemplateBytes(kind: kind, target: target, source: source)
        case .floorPlan(let value): return try encodedOperation("floor-plan", value)
        case .hierarchy(let value): return try encodedOperation("hierarchy", value)
        }
    }

    private static func ipamBytes(_ operation: PlannedIPAMOperation, intentSchemaVersion: Int) throws -> Data {
        var data = Data()
        append("ipam", to: &data)
        switch operation {
        case let .prefixLayout(vrf, revision, current, desired):
            try appendPrefixLayout(vrf: vrf, revision: revision, current: current, desired: desired, schemaVersion: intentSchemaVersion, to: &data)
        case let .addressAssignment(value): try appendAddressAssignments(value, to: &data)
        case let .vlanMembership(value): try appendVLANMemberships(value, to: &data)
        case let .legacyAddressAssignment(key, interfaceID):
            try appendLegacyAddress(key: key, interfaceID: interfaceID, schemaVersion: intentSchemaVersion, to: &data)
        case let .legacyVLANMembership(interfaceID, vlanID, isNative):
            try appendLegacyVLAN(interfaceID: interfaceID, vlanID: vlanID, isNative: isNative, schemaVersion: intentSchemaVersion, to: &data)
        }
        return data
    }

    private static func encodedOperation<T: Encodable>(_ label: String, _ value: T) throws -> Data {
        var data = Data()
        append(label, to: &data)
        append(try CanonicalJSONCoding.encode(value), to: &data)
        return data
    }

    private static func simpleBytes(_ label: String, values: [String]) -> Data {
        var data = Data()
        append(label, to: &data)
        for value in values { append(value, to: &data) }
        return data
    }

    private static func templateBytes(kind: PlannedTemplateChangeKind, target: DeviceType, source: ObjectID?, migrations: [DeviceTemplateMigrationPlan]) throws
        -> Data
    {
        var data = Data()
        append("template", to: &data)
        append(kind.rawValue, to: &data)
        append(source?.description, to: &data)
        append(try CanonicalJSONCoding.encode(target), to: &data)
        let ordered = migrations.sorted { $0.deviceID < $1.deviceID }
        append(ordered.count, to: &data)
        for migration in ordered { append(try CanonicalJSONCoding.encode(migration), to: &data) }
        return data
    }

    private static func moduleTemplateBytes(kind: PlannedTemplateChangeKind, target: ModuleTemplate, source: ObjectID?) throws -> Data {
        var data = Data()
        append("module-template", to: &data)
        append(kind.rawValue, to: &data)
        append(source?.description, to: &data)
        append(try CanonicalJSONCoding.encode(target), to: &data)
        return data
    }

    private static func appendPrefixLayout(vrf: VRF, revision: Int, current: [Prefix], desired: [Prefix], schemaVersion: Int, to data: inout Data) throws {
        append("prefix-layout", to: &data)
        append(vrf.id.description, to: &data)
        append(revision, to: &data)
        append(try CanonicalJSONCoding.encode(vrf), to: &data)
        if schemaVersion >= 2 { try appendPrefixes(current, to: &data) }
        try appendPrefixes(desired, to: &data)
    }

    private static func appendPrefixes(_ prefixes: [Prefix], to data: inout Data) throws {
        let ordered = prefixes.sorted { $0.id == $1.id ? $0.cidr < $1.cidr : $0.id < $1.id }
        append(ordered.count, to: &data)
        for prefix in ordered { append(try CanonicalJSONCoding.encode(prefix), to: &data) }
    }

    private static func appendAddressAssignments(_ value: InterfaceAddressAssignmentSet, to data: inout Data) throws {
        append("address-assignment", to: &data)
        append(value.interfaceID.description, to: &data)
        append(value.primaryAddressID, to: &data)
        try appendEncoded(value.currentAssignments.sorted(by: IPAMRelationshipSetOrdering.assignments), to: &data)
        try appendEncoded(value.desiredAssignments.sorted(by: IPAMRelationshipSetOrdering.assignments), to: &data)
    }

    private static func appendVLANMemberships(_ value: InterfaceVLANMembershipSet, to data: inout Data) throws {
        append("vlan-membership", to: &data)
        append(value.interfaceID.description, to: &data)
        try appendEncoded(value.currentMemberships.sorted(by: IPAMRelationshipSetOrdering.memberships), to: &data)
        try appendEncoded(value.desiredMemberships.sorted(by: IPAMRelationshipSetOrdering.memberships), to: &data)
    }

    private static func appendLegacyAddress(key: ResourceKey, interfaceID: ObjectID, schemaVersion: Int, to data: inout Data) throws {
        guard schemaVersion == 1 else { throw IntentDigestError.invalidSchemaVersion(schemaVersion) }
        append("address-assignment", to: &data)
        append(key.description, to: &data)
        append(interfaceID.description, to: &data)
    }

    private static func appendLegacyVLAN(interfaceID: ObjectID, vlanID: ObjectID, isNative: Bool, schemaVersion: Int, to data: inout Data) throws {
        guard schemaVersion == 1 else { throw IntentDigestError.invalidSchemaVersion(schemaVersion) }
        append("vlan-membership", to: &data)
        append(interfaceID.description, to: &data)
        append(vlanID.description, to: &data)
        append(isNative ? 1 : 0, to: &data)
    }

    private static func appendEncoded<T: Encodable>(_ values: [T], to data: inout Data) throws {
        append(values.count, to: &data)
        for value in values { append(try CanonicalJSONCoding.encode(value), to: &data) }
    }

    private static func append(_ value: String?, to data: inout Data) {
        guard let value else {
            append(-1, to: &data)
            return
        }
        append(Data(value.utf8), to: &data)
    }

    private static func append(_ value: Int, to data: inout Data) {
        append(String(value), to: &data)
    }

    private static func append(_ value: Data, to data: inout Data) {
        data.append(Data("\(value.count):".utf8))
        data.append(value)
    }
}
