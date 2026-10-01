import CloudSync
import ContentSafety
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

public struct TrustedProductionSession: Sendable {
    public let account: AccountContext
    let actor: ActorContext
    let actorSnapshot: ActorInstallationSnapshot
    let lease: CloudSessionLease
}

public protocol ProductionInstallationSessionProviding: Sendable {
    func sessionID(for actor: ActorContext, account: AccountContext) async throws -> String
}

enum ProductionSessionAuthorizationError: Error, Equatable, Sendable {
    case noVerifiedSession
    case namespaceMismatch
    case presentationMismatch
    case invalidSessionID
    case sessionSuperseded
}

/// Resolves mutation identity from the active Cloud session. Presentation
/// values are checked for consistency only; they never grant authority.
public actor ProductionSessionAuthorizer: CurrentAuthorizationContextProviding, CloudForegroundMembershipVerifying {
    private let lifecycle: CloudSessionLifecycle
    private let workspaceAuthority: any CloudWorkspaceAuthority
    private let actorProvider: any CloudForegroundActorContextProvider
    private let installationSession: any ProductionInstallationSessionProviding
    private var membershipVerification: (id: UUID, task: Task<CloudSessionEvent, Error>)?

    public init(
        lifecycle: CloudSessionLifecycle, workspaceAuthority: any CloudWorkspaceAuthority,
        actorProvider: any CloudForegroundActorContextProvider, installationSession: any ProductionInstallationSessionProviding
    ) {
        self.lifecycle = lifecycle
        self.workspaceAuthority = workspaceAuthority
        self.actorProvider = actorProvider
        self.installationSession = installationSession
    }

    func authorizeMutation(
        namespace: PersistenceNamespace, presentation: OperationsAuthorization, requiresAdministrator: Bool = false
    ) async throws -> TrustedProductionSession {
        let trusted = try await resolve(namespace: namespace, requiresAdministrator: requiresAdministrator)
        guard presentation.actorID == trusted.actor.cloudKitUserRecordName,
            presentation.role == trusted.actor.role,
            presentation.sessionGeneration == trusted.actor.sessionGeneration,
            presentation.isFresh
        else {
            throw ProductionSessionAuthorizationError.presentationMismatch
        }
        return trusted
    }

    func authorizeOperation(
        _ claimed: AuthorizedOperationContext, action: AuthorizedOperationAction, requiresAdministrator: Bool
    ) async throws -> TrustedProductionSession {
        guard claimed.action == action else {
            throw ProductionSessionAuthorizationError.presentationMismatch
        }
        let trusted = try await resolve(namespace: claimed.account.namespace, requiresAdministrator: requiresAdministrator)
        guard claimed.account == trusted.account,
            claimed.actor.cloudKitUserRecordName == trusted.actor.cloudKitUserRecordName,
            claimed.actor.role == trusted.actor.role,
            claimed.actor.installationID == trusted.actor.installationID,
            claimed.actor.sessionGeneration == trusted.actor.sessionGeneration,
            claimed.capturedSessionGeneration == trusted.account.namespace.sessionGeneration
        else {
            throw ProductionSessionAuthorizationError.presentationMismatch
        }
        return trusted
    }

    func revalidate(_ trusted: TrustedProductionSession) async throws {
        try await awaitInFlightMembershipVerification()
        guard await lifecycle.isCurrent(trusted.lease),
            let current = await lifecycle.activeContext(),
            current == trusted.account
        else {
            throw ProductionSessionAuthorizationError.sessionSuperseded
        }
        let actor = try await actorProvider.actorContext(for: current)
        guard await lifecycle.isCurrent(trusted.lease), actor == trusted.actor else {
            throw ProductionSessionAuthorizationError.sessionSuperseded
        }
        try OfficialClientPolicy.authorizeMutation(actor: actor, account: current, requiresAdministrator: trusted.actor.role == .administrator)
    }

    public func validateCurrent(_ context: AuthorizedOperationContext) async -> Bool {
        let requiresAdministrator: Bool
        switch context.action {
        case .createAttachment, .readAttachment:
            requiresAdministrator = false
        case .importCSV, .exportCSV, .exportAudit, .exportArchive, .restoreArchive:
            requiresAdministrator = true
        }
        do {
            let trusted = try await authorizeOperation(context, action: context.action, requiresAdministrator: requiresAdministrator)
            try await revalidate(trusted)
            return true
        } catch {
            return false
        }
    }

    private func resolve(namespace: PersistenceNamespace, requiresAdministrator: Bool) async throws -> TrustedProductionSession {
        let trusted = try await verifiedSession(namespace: namespace)
        try OfficialClientPolicy.authorizeMutation(actor: trusted.actor, account: trusted.account, requiresAdministrator: requiresAdministrator)
        return trusted
    }

    public func verifiedSession(namespace: PersistenceNamespace) async throws -> TrustedProductionSession {
        let event = try await verifyForegroundMembership()
        guard case .activated(let account) = event,
            account.namespace == namespace,
            let lease = await lifecycle.activeLease(),
            await lifecycle.isCurrent(lease)
        else {
            throw ProductionSessionAuthorizationError.noVerifiedSession
        }
        let actor = try await actorProvider.actorContext(for: account)
        guard await lifecycle.isCurrent(lease) else {
            throw ProductionSessionAuthorizationError.sessionSuperseded
        }
        let sessionID = try await installationSession.sessionID(for: actor, account: account)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty else {
            throw ProductionSessionAuthorizationError.invalidSessionID
        }
        guard await lifecycle.isCurrent(lease) else {
            throw ProductionSessionAuthorizationError.sessionSuperseded
        }
        return TrustedProductionSession(
            account: account,
            actor: actor,
            actorSnapshot: ActorInstallationSnapshot(
                actorID: actor.cloudKitUserRecordName, installationID: actor.installationID, sessionID: sessionID,
                sessionGeneration: actor.sessionGeneration, capturedAt: .now
            ),
            lease: lease
        )
    }

    public func verifyForegroundMembership() async throws -> CloudSessionEvent {
        try await verifiedMembershipEvent()
    }

    private func verifiedMembershipEvent() async throws -> CloudSessionEvent {
        let verification: (id: UUID, task: Task<CloudSessionEvent, Error>)
        if let current = membershipVerification {
            verification = current
        } else {
            let id = UUID()
            let lifecycle = self.lifecycle
            let workspaceAuthority = self.workspaceAuthority
            let task = Task {
                try await lifecycle.verifyForegroundMembership(using: workspaceAuthority)
            }
            verification = (id, task)
            membershipVerification = verification
        }
        do {
            let event = try await verification.task.value
            if membershipVerification?.id == verification.id {
                membershipVerification = nil
            }
            return event
        } catch {
            if membershipVerification?.id == verification.id {
                membershipVerification = nil
            }
            throw error
        }
    }

    private func awaitInFlightMembershipVerification() async throws {
        guard let verification = membershipVerification else { return }
        do {
            _ = try await verification.task.value
            if membershipVerification?.id == verification.id {
                membershipVerification = nil
            }
        } catch {
            if membershipVerification?.id == verification.id {
                membershipVerification = nil
            }
            throw error
        }
    }
}
