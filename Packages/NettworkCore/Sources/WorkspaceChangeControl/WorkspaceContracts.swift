import Foundation
import NetworkModel

public enum CloudDatabaseScope: String, Codable, Hashable, Sendable {
    case ownerPrivate
    case participantShared
}

public enum WorkspaceSharePermission: String, Codable, Hashable, Sendable {
    case readOnly
    case readWrite
    case owner
}

public enum OfficialClientRole: String, Codable, CaseIterable, Hashable, Sendable {
    case viewer
    case technician
    case administrator
}

/// Complete cache namespace. A generation change makes every older handle invalid.
public struct PersistenceNamespace: Codable, Hashable, Sendable {
    public let containerIdentifier: String
    public let cloudKitAccountRecordName: String
    public let workspaceID: ObjectID
    public let zoneName: String
    public let zoneOwnerRecordName: String
    public let sessionGeneration: UInt64

    public init(
        containerIdentifier: String, cloudKitAccountRecordName: String, workspaceID: ObjectID, zoneName: String, zoneOwnerRecordName: String,
        sessionGeneration: UInt64
    ) {
        self.containerIdentifier = containerIdentifier
        self.cloudKitAccountRecordName = cloudKitAccountRecordName
        self.workspaceID = workspaceID
        self.zoneName = zoneName
        self.zoneOwnerRecordName = zoneOwnerRecordName
        self.sessionGeneration = sessionGeneration
    }

    public var workspaceZone: AuthoritativeWorkspaceZone {
        AuthoritativeWorkspaceZone(
            workspaceID: workspaceID, containerIdentifier: containerIdentifier, zoneName: zoneName, zoneOwnerRecordName: zoneOwnerRecordName)
    }
}

public struct AccountContext: Codable, Hashable, Sendable {
    public let namespace: PersistenceNamespace
    public let databaseScope: CloudDatabaseScope
    public let sharePermission: WorkspaceSharePermission
    public let shareRecordName: String?
    public let verifiedAt: Date

    public init(
        namespace: PersistenceNamespace, databaseScope: CloudDatabaseScope, sharePermission: WorkspaceSharePermission, shareRecordName: String? = nil,
        verifiedAt: Date
    ) {
        self.namespace = namespace
        self.databaseScope = databaseScope
        self.sharePermission = sharePermission
        self.shareRecordName = shareRecordName
        self.verifiedAt = verifiedAt
    }
}

public struct ActorContext: Codable, Hashable, Sendable {
    public let cloudKitUserRecordName: String
    public let role: OfficialClientRole
    public let installationID: String
    public let sessionGeneration: UInt64

    public init(cloudKitUserRecordName: String, role: OfficialClientRole, installationID: String, sessionGeneration: UInt64) {
        self.cloudKitUserRecordName = cloudKitUserRecordName
        self.role = role
        self.installationID = installationID
        self.sessionGeneration = sessionGeneration
    }
}

public enum AuthorizedOperationAction: String, Codable, Hashable, Sendable {
    case createAttachment
    case readAttachment
    case importCSV
    case exportCSV
    case exportAudit
    case exportArchive
    case restoreArchive
}

public struct AuthorizedOperationContext: Codable, Hashable, Sendable {
    public let operationID: ObjectID
    public let account: AccountContext
    public let actor: ActorContext
    public let action: AuthorizedOperationAction
    public let capturedSessionGeneration: UInt64

    public init(operationID: ObjectID, account: AccountContext, actor: ActorContext, action: AuthorizedOperationAction) {
        self.operationID = operationID
        self.account = account
        self.actor = actor
        self.action = action
        self.capturedSessionGeneration = account.namespace.sessionGeneration
    }

    public func validateCurrent(account current: AccountContext) -> Bool {
        account == current && actor.cloudKitUserRecordName == current.namespace.cloudKitAccountRecordName
            && actor.sessionGeneration == current.namespace.sessionGeneration && capturedSessionGeneration == current.namespace.sessionGeneration
    }
}

public protocol MutationOutbox: Sendable {
    func enqueue(_ operation: OutboxOperation) async throws
    func operations(in namespace: PersistenceNamespace) async throws -> [OutboxOperation]
    /// Unaccepted operations plus the IDs of accepted ones; stores may skip decoding accepted history.
    func unacceptedOperations(in namespace: PersistenceNamespace) async throws -> (operations: [OutboxOperation], acceptedIDs: Set<ObjectID>)
    func status(in namespace: PersistenceNamespace) async throws -> OutboxStatus
    func recordAttempt(operationID: ObjectID, at date: Date, namespace: PersistenceNamespace) async throws
    func recordFailure(operationID: ObjectID, failure: SyncFailure, nextRetryAt: Date?, poison: Bool, namespace: PersistenceNamespace) async throws
    func recordAcceptance(operationID: ObjectID, receipt: OperationReceipt, namespace: PersistenceNamespace) async throws
}
extension MutationOutbox {
    public func unacceptedOperations(in namespace: PersistenceNamespace) async throws -> (operations: [OutboxOperation], acceptedIDs: Set<ObjectID>) {
        let all = try await operations(in: namespace)
        return (all.filter { $0.state != .accepted }, Set(all.filter { $0.state == .accepted && $0.receipt != nil }.map(\.operationID)))
    }
}
public protocol SyncCoordinator: Sendable { func synchronizeForeground() async -> SyncReceipt }
public protocol ConflictResolver: Sendable {
    func capture(_ conflict: ReconciliationCase) async throws
    func unresolvedCases(in namespace: PersistenceNamespace) async throws -> [ReconciliationCase]
}
