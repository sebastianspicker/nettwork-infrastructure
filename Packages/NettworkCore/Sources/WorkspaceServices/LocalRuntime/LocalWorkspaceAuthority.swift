import CloudSync
import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Typed failures of the local authority, actor and installation providers.
public enum LocalWorkspaceAuthorityError: Error, Equatable, Sendable {
    /// A local workspace has exactly one owner; sharing operations do not exist.
    case sharingUnavailable
    /// The account being resolved is not the persisted local identity.
    case accountMismatch
    case invalidInstallationSession
}

extension LocalWorkspaceAuthorityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sharingUnavailable: "Sharing is not available for a local workspace."
        case .accountMismatch: "The account does not belong to the local workspace identity."
        case .invalidInstallationSession: "The local installation session identifier is empty."
        }
    }
}

/// Fail-closed workspace authority backed by the persisted local identity. The
/// identity is read on every call, so a deleted or corrupt file makes the
/// account unavailable at once instead of being papered over.
public struct LocalWorkspaceAuthority: CloudWorkspaceAuthority {
    private let identityDirectory: URL

    public init(identityDirectory: URL) {
        self.identityDirectory = identityDirectory
    }

    public func currentAccount() async throws -> CloudAccountIdentity {
        do {
            let identity = try LocalWorkspaceIdentity.load(from: identityDirectory)
            return CloudAccountIdentity(cloudKitUserRecordName: identity.userID, isAvailable: true)
        } catch {
            return CloudAccountIdentity(cloudKitUserRecordName: "", isAvailable: false)
        }
    }

    /// Refreshes the context only if it is exactly the owner-private namespace derived from the
    /// persisted identity (any session generation); every other context is revoked with `nil`.
    /// The caller's `verifiedAt` is kept: authorities compare whole contexts, and a
    /// local identity has no remote state whose verification time could advance.
    public func verifyMembership(for context: AccountContext) async throws -> AccountContext? {
        let identity: LocalWorkspaceIdentity
        do { identity = try LocalWorkspaceIdentity.load(from: identityDirectory) } catch { return nil }
        let generation = context.namespace.sessionGeneration
        guard context.namespace == identity.namespace(sessionGeneration: generation), context.databaseScope == .ownerPrivate,
            context.sharePermission == .owner, context.shareRecordName == nil
        else { return nil }
        return identity.ownerContext(sessionGeneration: generation, verifiedAt: context.verifiedAt)
    }

    public func createWorkspace(workspaceID _: ObjectID, containerIdentifier _: String) async throws -> AccountContext {
        throw LocalWorkspaceAuthorityError.sharingUnavailable
    }

    public func inviteParticipant(owner _: AccountContext, participantCloudKitUserRecordName _: String, permission _: WorkspaceSharePermission) async throws
        -> Data
    { throw LocalWorkspaceAuthorityError.sharingUnavailable }

    public func acceptShare(metadata _: Data) async throws -> AccountContext { throw LocalWorkspaceAuthorityError.sharingUnavailable }

    public func revokeShare(owner _: AccountContext, shareRecordName _: String) async throws { throw LocalWorkspaceAuthorityError.sharingUnavailable }
}
