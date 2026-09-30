import CloudSync
import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl

enum ProductionWorkspaceAdministrationError: LocalizedError {
    case namespaceMismatch
    case ownerAdministratorRequired
    case invalidParticipantRecordName
    case invalidParticipantPermission
    case invalidInvitationMetadata
    case accountUnavailable
    case acceptedShareAccountMismatch
    case acceptedShareMembershipUnavailable
    case missingCurrentShare

    var errorDescription: String? {
        switch self {
        case .namespaceMismatch:
            "Workspace administration was requested outside the configured workspace."
        case .ownerAdministratorRequired:
            "Workspace invitations and revocation require a verified owner administrator session."
        case .invalidParticipantRecordName:
            "A participant CloudKit record name is required."
        case .invalidParticipantPermission:
            "Workspace ownership cannot be granted through a participant invitation."
        case .invalidInvitationMetadata:
            "The received workspace invitation is invalid."
        case .accountUnavailable:
            "The current CloudKit account is unavailable."
        case .acceptedShareAccountMismatch:
            "The accepted share belongs to a different CloudKit account."
        case .acceptedShareMembershipUnavailable:
            "The accepted share could not be verified for the current account."
        case .missingCurrentShare:
            "There is no current workspace share to revoke."
        }
    }
}

/// Production-only workspace administration boundary. It owns no CloudKit
/// transport and performs every share mutation through CloudWorkspaceAuthority.
@MainActor
final class ProductionWorkspaceAdministrationAuthority: WorkspaceAdministrationService {
    private let account: AccountContext
    private let workspaceName: String
    private let lifecycle: CloudSessionLifecycle
    private let workspaceAuthority: any CloudWorkspaceAuthority
    private let sessionAuthorizer: ProductionSessionAuthorizer
    private let acceptedShareActivation: @MainActor (AccountContext) async throws -> Void

    init(
        account: AccountContext,
        workspaceName: String,
        lifecycle: CloudSessionLifecycle,
        workspaceAuthority: any CloudWorkspaceAuthority,
        sessionAuthorizer: ProductionSessionAuthorizer,
        acceptedShareActivation: @escaping @MainActor (AccountContext) async throws -> Void
    ) {
        self.account = account
        self.workspaceName = workspaceName
        self.lifecycle = lifecycle
        self.workspaceAuthority = workspaceAuthority
        self.sessionAuthorizer = sessionAuthorizer
        self.acceptedShareActivation = acceptedShareActivation
    }

    func participantStatus() async throws -> WorkspaceParticipantStatusPresentation {
        let trusted = try await verifiedSession()
        return status(from: trusted)
    }

    func inviteParticipant(_ request: WorkspaceInviteRequest) async throws -> WorkspaceInviteReceipt {
        let participantRecordName = request.participantCloudKitUserRecordName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !participantRecordName.isEmpty else {
            throw ProductionWorkspaceAdministrationError.invalidParticipantRecordName
        }
        guard request.permission != .owner else {
            throw ProductionWorkspaceAdministrationError.invalidParticipantPermission
        }
        let trusted = try await verifiedOwnerAdministrator()
        try await sessionAuthorizer.revalidate(trusted)
        let metadata = try await workspaceAuthority.inviteParticipant(
            owner: trusted.account, participantCloudKitUserRecordName: participantRecordName, permission: request.permission
        )
        guard !metadata.isEmpty else {
            throw ProductionWorkspaceAdministrationError.invalidInvitationMetadata
        }
        return WorkspaceInviteReceipt(participantCloudKitUserRecordName: participantRecordName, shareMetadata: metadata)
    }

    func acceptShare(metadata: Data) async throws -> WorkspaceAcceptedShare {
        guard !metadata.isEmpty else {
            throw ProductionWorkspaceAdministrationError.invalidInvitationMetadata
        }
        let currentAccount = try await workspaceAuthority.currentAccount()
        guard currentAccount.isAvailable else {
            throw ProductionWorkspaceAdministrationError.accountUnavailable
        }
        let accepted = try await workspaceAuthority.acceptShare(metadata: metadata)
        guard accepted.namespace.cloudKitAccountRecordName == currentAccount.cloudKitUserRecordName else {
            throw ProductionWorkspaceAdministrationError.acceptedShareAccountMismatch
        }
        guard let refreshed = try await workspaceAuthority.verifyMembership(for: accepted),
            refreshed.namespace == accepted.namespace,
            refreshed.databaseScope == .participantShared,
            refreshed.shareRecordName != nil
        else {
            throw ProductionWorkspaceAdministrationError.acceptedShareMembershipUnavailable
        }
        try await acceptedShareActivation(refreshed)
        return WorkspaceAcceptedShare(
            account: refreshed,
            presentation: WorkspaceParticipantStatusPresentation(
                workspaceName: workspaceName, participantRecordName: currentAccount.cloudKitUserRecordName, role: nil,
                permission: refreshed.sharePermission, shareRecordName: refreshed.shareRecordName, membershipIsVerified: true,
                disclosure: OfficialClientPolicy.limitation
            )
        )
    }

    func revokeCurrentShare() async throws {
        let trusted = try await verifiedOwnerAdministrator()
        guard
            let shareRecordName = trusted.account.shareRecordName?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !shareRecordName.isEmpty
        else {
            throw ProductionWorkspaceAdministrationError.missingCurrentShare
        }
        try await sessionAuthorizer.revalidate(trusted)
        do {
            try await workspaceAuthority.revokeShare(owner: trusted.account, shareRecordName: shareRecordName)
        } catch {
            // A transport failure may follow a remote revoke. Retire the
            // local session rather than retaining possibly revoked access.
            await lifecycle.invalidateCurrentSession()
            throw error
        }
        await lifecycle.invalidateCurrentSession()
    }

    private func verifiedSession() async throws -> TrustedProductionSession {
        let trusted = try await sessionAuthorizer.verifiedSession(namespace: account.namespace)
        guard trusted.account.namespace == account.namespace else {
            throw ProductionWorkspaceAdministrationError.namespaceMismatch
        }
        return trusted
    }

    private func verifiedOwnerAdministrator() async throws -> TrustedProductionSession {
        let trusted = try await verifiedSession()
        guard trusted.account.databaseScope == .ownerPrivate,
            trusted.account.sharePermission == .owner,
            trusted.actor.role == .administrator
        else {
            throw ProductionWorkspaceAdministrationError.ownerAdministratorRequired
        }
        try OfficialClientPolicy.authorizeMutation(actor: trusted.actor, account: trusted.account, requiresAdministrator: true)
        return trusted
    }

    private func status(from trusted: TrustedProductionSession) -> WorkspaceParticipantStatusPresentation {
        WorkspaceParticipantStatusPresentation(
            workspaceName: workspaceName, participantRecordName: trusted.actor.cloudKitUserRecordName, role: trusted.actor.role,
            permission: trusted.account.sharePermission, shareRecordName: trusted.account.shareRecordName, membershipIsVerified: true,
            disclosure: OfficialClientPolicy.limitation
        )
    }
}
