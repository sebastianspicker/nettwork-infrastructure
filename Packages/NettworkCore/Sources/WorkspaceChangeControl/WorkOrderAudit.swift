import CryptoKit
import Foundation
import NetworkModel

public enum AuditSource: String, Codable, Sendable { case interactive, offlineOutbox, importExport, reconciliation }
public enum AuditErrorClassification: String, Codable, Sendable { case validation, conflict, authorization, network, quota, account, unknown }

public struct AuditRecordChange: Codable, Hashable, Sendable {
    public let resourceKey: ResourceKey
    public let before: Data?
    public let after: Data?
    public let patch: Data?
    public init(resourceKey: ResourceKey, before: Data? = nil, after: Data? = nil, patch: Data? = nil) {
        self.resourceKey = resourceKey
        self.before = before
        self.after = after
        self.patch = patch
    }
}

public struct AuditEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: ObjectID
    public var operationID: ObjectID
    public var correlationID: ObjectID
    public var actorID: String
    public var installationID: String?
    public var sessionID: String?
    public var sessionGeneration: UInt64?
    public var source: AuditSource
    public var affectedObjectIDs: [ObjectID]
    public var affectedResourceKeys: [ResourceKey]
    public var changes: [AuditRecordChange]
    public var workOrderID: ObjectID?
    public var ticket: String?
    public var occurredAt: Date
    public var serverOccurredAt: Date?
    public var policyVersion: String
    public var cloudKitChangeTags: [ResourceKey: String]
    public var result: Result
    public var errorClassification: AuditErrorClassification?
    public enum Result: String, Codable, Sendable { case accepted, rejected }

    public init(
        id: ObjectID = .init(), operationID: ObjectID, actorID: String, affectedObjectIDs: [ObjectID], workOrderID: ObjectID? = nil, occurredAt: Date = .now,
        result: Result, correlationID: ObjectID? = nil,
        installationID: String? = nil, sessionID: String? = nil, sessionGeneration: UInt64? = nil, source: AuditSource = .interactive,
        affectedResourceKeys: [ResourceKey] = [], changes: [AuditRecordChange] = [],
        ticket: String? = nil, serverOccurredAt: Date? = nil, policyVersion: String = "unspecified", cloudKitChangeTags: [ResourceKey: String] = [:],
        errorClassification: AuditErrorClassification? = nil
    ) {
        self.id = id
        self.operationID = operationID
        self.correlationID = correlationID ?? operationID
        self.actorID = actorID
        self.installationID = installationID
        self.sessionID = sessionID
        self.sessionGeneration = sessionGeneration
        self.source = source
        self.affectedObjectIDs = affectedObjectIDs
        self.affectedResourceKeys = affectedResourceKeys
        self.changes = changes
        self.workOrderID = workOrderID
        self.ticket = ticket
        self.occurredAt = occurredAt
        self.serverOccurredAt = serverOccurredAt
        self.policyVersion = policyVersion
        self.cloudKitChangeTags = cloudKitChangeTags
        self.result = result
        self.errorClassification = errorClassification
    }

    public static func deterministicID(for operationID: ObjectID) -> ObjectID {
        DeterministicWorkOrderObjectID.make(domain: "audit-event", seed: operationID.description)
    }
}

enum DeterministicWorkOrderObjectID {
    static func make(domain: String, seed: String) -> ObjectID {
        let material = Data("nettwork.\(domain).v1\0\(seed)".utf8)
        let hex = SHA256.hash(data: material).map { String(format: "%02x", $0) }.joined()
        let value =
            "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        guard let uuid = UUID(uuidString: value) else {
            preconditionFailure("A SHA-256-derived UUID must be syntactically valid.")
        }
        return ObjectID(uuid)
    }
}
