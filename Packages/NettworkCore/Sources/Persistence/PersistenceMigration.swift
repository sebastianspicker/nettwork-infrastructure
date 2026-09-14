import CryptoKit
import Foundation
import NetworkModel
import SwiftData
import WorkspaceChangeControl

/// Single production construction boundary so every persistent container is
/// configured with the schema history rather than an integer-only marker.
public enum NettworkPersistenceContainerFactory {
    public static func make(configurations: [ModelConfiguration]) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: NettworkLocalSchemaV9.self),
            migrationPlan: NettworkLocalSchemaMigrationPlan.self, configurations: configurations)
    }

    public static func make(configuration: ModelConfiguration) throws -> ModelContainer {
        try make(configurations: [configuration])
    }
}

public struct LegacyOutboxEvidence: Codable, Hashable, Sendable {
    public let operationID: String
    public let namespaceKey: String
    public let kind: String
    public let payload: Data
    public let baseChangeTags: Data
    public let createdAt: Date
    public let attemptCount: Int
    public let lastError: String?

    public init(
        operationID: String, namespaceKey: String, kind: String, payload: Data, baseChangeTags: Data, createdAt: Date, attemptCount: Int, lastError: String?
    ) {
        self.operationID = operationID
        self.namespaceKey = namespaceKey
        self.kind = kind
        self.payload = payload
        self.baseChangeTags = baseChangeTags
        self.createdAt = createdAt
        self.attemptCount = attemptCount
        self.lastError = lastError
    }
}

public struct LegacyOutboxPayload: Codable, Hashable, Sendable {
    public let operationID: ObjectID
    public let kind: String
    public let payload: Data
    public let baseChangeTags: Data
    public let createdAt: Date
    public let attemptCount: Int

    public init(operationID: ObjectID, kind: String, payload: Data, baseChangeTags: Data, createdAt: Date, attemptCount: Int) {
        self.operationID = operationID
        self.kind = kind
        self.payload = payload
        self.baseChangeTags = baseChangeTags
        self.createdAt = createdAt
        self.attemptCount = attemptCount
    }
}

public enum PersistenceMigrationError: Error, Hashable, Sendable {
    case legacyEnvelopeUnavailable(ObjectID)
    case legacyBaseStateUnavailable(ObjectID)
    case legacyNamespaceMismatch(ObjectID)
}

public enum LegacyOutboxMigrationDisposition: Hashable, Sendable {
    case migrated(OutboxOperation)
    case requiresReconciliation(LegacyOutboxPayload, PersistenceMigrationError)
}

/// Explicit v1-to-v2 migration policy. Legacy rows remain intact unless the
/// caller has the original immutable envelope and encoded base state; this is
/// deliberately stricter than a lightweight SwiftData migration because the
/// obsolete payload lacked the exact evidence required for safe replay.
public struct NettworkPersistenceMigrationPlan: Sendable {
    public static let v1ToV2 = Self(sourceSchemaVersion: 1, targetSchemaVersion: NettworkLocalSchema.version)

    public let sourceSchemaVersion: Int
    public let targetSchemaVersion: Int

    public init(sourceSchemaVersion: Int, targetSchemaVersion: Int) {
        self.sourceSchemaVersion = sourceSchemaVersion
        self.targetSchemaVersion = targetSchemaVersion
    }

    public func migrate(
        legacy: LegacyOutboxPayload, namespace: PersistenceNamespace, envelope: ExecutionEnvelope?, resourceKeys: Set<ResourceKey>,
        dependencyOperationIDs: Set<ObjectID>
    ) -> LegacyOutboxMigrationDisposition {
        do {
            return .migrated(
                try NettworkPersistenceMigration.migrate(
                    legacy: legacy, namespace: namespace, envelope: envelope, resourceKeys: resourceKeys, dependencyOperationIDs: dependencyOperationIDs))
        } catch let error as PersistenceMigrationError {
            return .requiresReconciliation(legacy, error)
        } catch {
            return .requiresReconciliation(legacy, .legacyEnvelopeUnavailable(legacy.operationID))
        }
    }
}

/// The pre-release v1 outbox cannot be safely guessed into a v2 operation.
/// A caller must supply the original envelope and its non-empty encoded base
/// state; otherwise the legacy row is retained for explicit reconciliation.
public enum NettworkPersistenceMigration {
    public static func migrate(
        legacy: LegacyOutboxPayload, namespace: PersistenceNamespace, envelope: ExecutionEnvelope?, resourceKeys: Set<ResourceKey>,
        dependencyOperationIDs: Set<ObjectID>
    ) throws -> OutboxOperation {
        guard !legacy.baseChangeTags.isEmpty else { throw PersistenceMigrationError.legacyBaseStateUnavailable(legacy.operationID) }
        guard let envelope else { throw PersistenceMigrationError.legacyEnvelopeUnavailable(legacy.operationID) }
        guard envelope.accountContext.namespace == namespace,
            envelope.actorContext.sessionGeneration == namespace.sessionGeneration
        else {
            throw PersistenceMigrationError.legacyNamespaceMismatch(legacy.operationID)
        }
        return OutboxOperation(
            operationID: legacy.operationID, namespace: namespace, envelope: envelope,
            resourceKeys: resourceKeys, dependencyOperationIDs: dependencyOperationIDs,
            createdAt: legacy.createdAt, attemptCount: legacy.attemptCount)
    }
}

enum PersistenceCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
