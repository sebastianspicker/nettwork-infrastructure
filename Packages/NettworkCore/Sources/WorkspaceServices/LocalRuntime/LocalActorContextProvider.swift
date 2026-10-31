import CloudSync
import Foundation
import WorkspaceChangeControl

/// Resolves the single local administrator. The role is fixed by this type and
/// is only reachable through the local runtime selection; the account must
/// belong to the persisted identity or resolution throws.
public struct LocalActorContextProvider: CloudForegroundActorContextProvider {
    private let identityDirectory: URL
    private let installationID: String

    public init(identityDirectory: URL, installationID: String) {
        self.identityDirectory = identityDirectory
        self.installationID = installationID
    }

    public func actorContext(for account: AccountContext) async throws -> ActorContext {
        let identity = try LocalWorkspaceIdentity.load(from: identityDirectory)
        guard account.namespace.cloudKitAccountRecordName == identity.userID else { throw LocalWorkspaceAuthorityError.accountMismatch }
        return ActorContext(
            cloudKitUserRecordName: identity.userID, role: .administrator, installationID: installationID,
            sessionGeneration: account.namespace.sessionGeneration)
    }
}
