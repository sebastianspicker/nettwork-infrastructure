import Foundation
import NetworkModel
import WorkspaceChangeControl

public struct AuditEventPresentation: Identifiable, Equatable, Sendable {
    public let event: AuditEvent
    public let summary: String
    public var id: ObjectID { event.id }

    public init(event: AuditEvent, summary: String) {
        self.event = event
        self.summary = summary
    }
}

public struct OperationsReport: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let generatedAt: Date
    public let summary: String
    public let isFinal: Bool

    public init(id: String, title: String, generatedAt: Date, summary: String, isFinal: Bool) {
        self.id = id
        self.title = title
        self.generatedAt = generatedAt
        self.summary = summary
        self.isFinal = isFinal
    }
}

public struct WorkspaceAccessPresentation: Equatable, Sendable {
    public let workspaceName: String
    public let accountRecordName: String
    public let role: OfficialClientRole
    public let permission: WorkspaceSharePermission
    public let policyVersion: String
    public let disclosure: String

    public init(
        workspaceName: String,
        accountRecordName: String,
        role: OfficialClientRole,
        permission: WorkspaceSharePermission,
        policyVersion: String,
        disclosure: String
    ) {
        self.workspaceName = workspaceName
        self.accountRecordName = accountRecordName
        self.role = role
        self.permission = permission
        self.policyVersion = policyVersion
        self.disclosure = disclosure
    }
}

public struct SyncHealthPresentation: Equatable, Sendable {
    public let mirror: SyncMirrorPresentation
    public let queueDescription: String
    public let quarantineDescription: String
    public let backupDescription: String
    public let accountFresh: Bool

    public init(
        mirror: SyncMirrorPresentation,
        queueDescription: String,
        quarantineDescription: String,
        backupDescription: String,
        accountFresh: Bool
    ) {
        self.mirror = mirror
        self.queueDescription = queueDescription
        self.quarantineDescription = quarantineDescription
        self.backupDescription = backupDescription
        self.accountFresh = accountFresh
    }
}

public struct SyncMirrorPresentation: Equatable, Sendable {
    public let conflictCount: Int
    public let lastSuccessfulServerContact: Date?

    public init(conflictCount: Int, lastSuccessfulServerContact: Date?) {
        self.conflictCount = conflictCount
        self.lastSuccessfulServerContact = lastSuccessfulServerContact
    }
}

@MainActor
public protocol OperationsReadModel {
    func auditEvents(matching query: String) async throws -> [AuditEventPresentation]
    func reports() async throws -> [OperationsReport]
    func syncHealth() async throws -> SyncHealthPresentation
    func workspaceAccess() async throws -> WorkspaceAccessPresentation
    func exportImmutableAudit(authorization: AuthorizedOperationContext) async throws -> URL
}

public struct ReconciliationComparison: Identifiable, Equatable, Sendable {
    public let id: ObjectID
    public let title: String
    public let reason: String
    public let baseSummary: String
    public let intendedSummary: String
    public let currentSummary: String
    public let isSecurityEvent: Bool

    public init(
        id: ObjectID,
        title: String,
        reason: String,
        baseSummary: String,
        intendedSummary: String,
        currentSummary: String,
        isSecurityEvent: Bool
    ) {
        self.id = id
        self.title = title
        self.reason = reason
        self.baseSummary = baseSummary
        self.intendedSummary = intendedSummary
        self.currentSummary = currentSummary
        self.isSecurityEvent = isSecurityEvent
    }
}

@MainActor
public protocol ReconciliationFeatureService {
    func unresolvedComparisons() async throws -> [ReconciliationComparison]
    func createCorrectiveWorkOrder(for reconciliationID: ObjectID, authorization: OperationsAuthorization) async throws -> ObjectID
}
