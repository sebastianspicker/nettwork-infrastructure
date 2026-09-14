import CloudSync
import NetworkModel
import Persistence
import WorkspaceChangeControl

extension ProductionWorkspaceTransferAuthority {
    func currentAccount() async throws -> AccountContext {
        let trusted = try await trustedSession(in: account.namespace)
        try await sessionAuthorizer.revalidate(trusted)
        return trusted.account
    }

    func workspaceIsEmpty(in namespace: PersistenceNamespace) async throws -> Bool {
        let trusted = try await trustedSession(in: namespace)
        let sentinel = try await bootstrapSentinel(in: namespace)
        try await sessionAuthorizer.revalidate(trusted)
        if case .empty = sentinel.workspace.lifecycle { return true }
        return false
    }

    func isFreshAuthenticatedTarget(in namespace: PersistenceNamespace) async throws -> Bool {
        try await workspaceIsEmpty(in: namespace)
    }
}
