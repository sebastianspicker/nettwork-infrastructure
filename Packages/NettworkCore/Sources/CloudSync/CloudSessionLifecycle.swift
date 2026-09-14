import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum OfficialClientPolicyError: Error, Hashable, Sendable {
    case viewerCannotMutate
    case technicianCannotAdminister
    case staleActorSession
    case accountMismatch
    case readOnlyShareCannotMutate
}

/// A product policy for official app clients only. CloudKit shares grant coarse
/// access; this cannot protect a workspace from a hostile writable participant.
public enum OfficialClientPolicy {
    public static let limitation = "Official-client roles are a UI and client policy, not hostile-client authorization."

    public static func authorizeMutation(actor: ActorContext, account: AccountContext, requiresAdministrator: Bool = false) throws {
        guard actor.sessionGeneration == account.namespace.sessionGeneration else { throw OfficialClientPolicyError.staleActorSession }
        guard actor.cloudKitUserRecordName == account.namespace.cloudKitAccountRecordName else { throw OfficialClientPolicyError.accountMismatch }
        guard account.sharePermission != .readOnly else { throw OfficialClientPolicyError.readOnlyShareCannotMutate }
        switch actor.role {
        case .viewer: throw OfficialClientPolicyError.viewerCannotMutate
        case .technician where requiresAdministrator: throw OfficialClientPolicyError.technicianCannotAdminister
        case .technician, .administrator: return
        }
    }
}

public enum CloudSessionEvent: Hashable, Sendable {
    case activated(AccountContext)
    case invalidated, revoked
}

public struct CloudSessionLease: Hashable, Sendable {
    public let namespace: PersistenceNamespace
    public let generation: UInt64
    public init(namespace: PersistenceNamespace, generation: UInt64) {
        self.namespace = namespace
        self.generation = generation
    }
}

public enum CloudSessionError: Error, Hashable, Sendable { case superseded }

public enum CloudAccountContextMatcher {
    /// Verification timestamps change routinely; they do not themselves imply a
    /// new account/share cache namespace or invalidate a preserved outbox item.
    public static func sameScope(_ lhs: AccountContext, _ rhs: AccountContext) -> Bool {
        lhs.namespace == rhs.namespace && lhs.databaseScope == rhs.databaseScope && lhs.sharePermission == rhs.sharePermission
            && lhs.shareRecordName == rhs.shareRecordName
    }
}

/// Serializes account/share changes. Generation comparison prevents an old
/// in-flight foreground refresh from writing into a newly opened local store.
public actor CloudSessionLifecycle {
    private let store: any CloudScopedStore
    private var context: AccountContext?
    private var generation: UInt64 = 0

    public init(store: any CloudScopedStore) { self.store = store }

    public func activeContext() -> AccountContext? { context }
    public func activeGeneration() -> UInt64 { generation }
    public func activeLease() -> CloudSessionLease? { context.map { CloudSessionLease(namespace: $0.namespace, generation: generation) } }

    @discardableResult
    public func activate(_ next: AccountContext) async throws -> CloudSessionEvent {
        if let context, CloudAccountContextMatcher.sameScope(context, next) {
            self.context = next
            return .activated(next)
        }
        let retired = retireCurrentSession()
        if let previous = retired.context { await store.close(namespace: previous.namespace) }
        await store.purgeEphemeralState()
        guard generation == retired.generation else { throw CloudSessionError.superseded }
        try await store.open(namespace: next.namespace)
        guard generation == retired.generation else {
            await store.close(namespace: next.namespace)
            throw CloudSessionError.superseded
        }
        context = next
        return .activated(next)
    }

    @discardableResult
    public func verifyForegroundMembership(using authority: any CloudWorkspaceAuthority) async throws -> CloudSessionEvent {
        guard let previous = context else { return .invalidated }
        let expectedGeneration = generation
        let account = try await verifiedAccount(authority, previous: previous, generation: expectedGeneration)
        guard isCurrent(previous, generation: expectedGeneration) else { return .invalidated }
        guard accountMatches(previous, account: account) else {
            await invalidateVerifiedSession(previous, expectedGeneration: expectedGeneration)
            return .invalidated
        }
        let refreshed = try await verifiedMembership(authority, previous: previous, generation: expectedGeneration)
        guard let refreshed else {
            await invalidateVerifiedSession(previous, expectedGeneration: expectedGeneration)
            return .revoked
        }
        guard isCompatible(refreshed, with: previous, account: account, generation: expectedGeneration) else {
            await invalidateVerifiedSession(previous, expectedGeneration: expectedGeneration)
            return .invalidated
        }
        if !CloudAccountContextMatcher.sameScope(previous, refreshed) {
            // Permission/share-record changes deliberately rotate the lease and
            // reopen scoped persistence. They are authorization changes, not a
            // harmless verification timestamp refresh.
            return try await activate(refreshed)
        }
        // Same-scope verification refreshes metadata without closing the
        // already-open store or rotating the lease generation. Concurrent
        // authorized work therefore cannot supersede itself merely because a
        // second feature performs the same membership check.
        context = refreshed
        return .activated(refreshed)
    }

    private func verifiedAccount(
        _ authority: any CloudWorkspaceAuthority, previous: AccountContext, generation: UInt64
    ) async throws -> CloudAccountIdentity {
        do {
            return try await authority.currentAccount()
        } catch {
            await invalidateVerifiedSession(previous, expectedGeneration: generation)
            throw error
        }
    }

    private func verifiedMembership(
        _ authority: any CloudWorkspaceAuthority, previous: AccountContext, generation: UInt64
    ) async throws -> AccountContext? {
        do {
            return try await authority.verifyMembership(for: previous)
        } catch {
            await invalidateVerifiedSession(previous, expectedGeneration: generation)
            throw error
        }
    }

    private func isCurrent(_ previous: AccountContext, generation: UInt64) -> Bool {
        generation == self.generation && context.map { CloudAccountContextMatcher.sameScope($0, previous) } == true
    }

    private func accountMatches(_ context: AccountContext, account: CloudAccountIdentity) -> Bool {
        account.isAvailable && account.cloudKitUserRecordName == context.namespace.cloudKitAccountRecordName
    }

    private func isCompatible(
        _ refreshed: AccountContext, with previous: AccountContext, account: CloudAccountIdentity, generation: UInt64
    ) -> Bool {
        isCurrent(previous, generation: generation)
            && refreshed.namespace.cloudKitAccountRecordName == account.cloudKitUserRecordName
            && refreshed.namespace == previous.namespace
            && refreshed.databaseScope == previous.databaseScope
    }

    public func invalidateCurrentSession() async {
        let retired = retireCurrentSession()
        if let context = retired.context { await store.close(namespace: context.namespace) }
        await store.purgeEphemeralState()
    }

    public func isCurrent(_ namespace: PersistenceNamespace, generation expectedGeneration: UInt64) -> Bool {
        context?.namespace == namespace && generation == expectedGeneration
    }

    public func isCurrent(_ lease: CloudSessionLease) -> Bool { isCurrent(lease.namespace, generation: lease.generation) }

    private func retireCurrentSession() -> (context: AccountContext?, generation: UInt64) {
        let previous = context
        context = nil
        generation &+= 1
        return (previous, generation)
    }

    private func invalidateVerifiedSession(
        _ expectedContext: AccountContext, expectedGeneration: UInt64
    ) async {
        guard generation == expectedGeneration, let current = context,
            CloudAccountContextMatcher.sameScope(current, expectedContext)
        else {
            return
        }
        let retired = retireCurrentSession()
        if let context = retired.context { await store.close(namespace: context.namespace) }
        await store.purgeEphemeralState()
    }
}
