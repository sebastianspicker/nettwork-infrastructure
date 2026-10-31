#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    /// File-backed `CloudKitWorkspaceContextStore`. Only contexts this store has
    /// created (owner) or admitted after a CloudKit share acceptance (participant)
    /// can be refreshed; every refresh re-reads zone and share membership from
    /// CloudKit. An unchanged membership returns the caller's context by value,
    /// `verifiedAt` included, because authorities compare whole contexts.
    public actor ProductionCloudKitWorkspaceContextStore: CloudKitWorkspaceContextStore {
        private let containerIdentifier: String
        private let file: CloudKitWorkspaceContextFile
        private let reader: any CloudKitWorkspaceMembershipReading
        private let now: @Sendable () -> Date

        /// - Parameters:
        ///   - container: The configured container; its identifier bounds every context.
        ///   - directory: Private directory that holds one context file per account.
        public init(container: CKContainer, directory: URL, now: @escaping @Sendable () -> Date = { Date() }) {
            self.init(
                containerIdentifier: container.containerIdentifier ?? "", directory: directory, reader: CloudKitContainerWorkspaceReader(container: container),
                now: now)
        }

        init(containerIdentifier: String, directory: URL, reader: any CloudKitWorkspaceMembershipReading, now: @escaping @Sendable () -> Date) {
            self.containerIdentifier = containerIdentifier
            self.file = CloudKitWorkspaceContextFile(directory: directory)
            self.reader = reader
            self.now = now
        }

        /// Returns the persisted owner context for the workspace, creating it once.
        /// It names the zone-wide share the bootstrapper creates with the zone.
        public func ownerContext(workspaceID: ObjectID, containerIdentifier: String, accountRecordName: String) async throws -> AccountContext {
            guard !self.containerIdentifier.isEmpty, containerIdentifier == self.containerIdentifier else { throw CloudKitWorkspaceError.containerMismatch }
            guard CloudKitWorkspaceContextRules.isValidRecordName(accountRecordName) else { throw CloudKitWorkspaceError.invalidContext }
            let namespace = CloudKitWorkspaceContextRules.ownerNamespace(
                workspaceID: workspaceID, containerIdentifier: containerIdentifier, accountRecordName: accountRecordName)
            var contexts = try file.contexts(accountRecordName: accountRecordName)
            if let existing = contexts.first(where: { $0.namespace == namespace && $0.databaseScope == .ownerPrivate }) { return existing }
            let context = AccountContext(
                namespace: namespace, databaseScope: .ownerPrivate, sharePermission: .owner, shareRecordName: CKRecordNameZoneWideShare, verifiedAt: now())
            contexts.append(context)
            try file.persist(contexts, accountRecordName: accountRecordName)
            return context
        }

        /// Accepts the share in CloudKit, then admits it only as an accepted,
        /// zone-wide, non-owner membership of a Nettwork workspace zone.
        public func acceptedShareContext(metadata: Data, accountRecordName: String) async throws -> AccountContext {
            guard CloudKitWorkspaceContextRules.isValidRecordName(accountRecordName) else { throw CloudKitWorkspaceError.invalidContext }
            let facts = try await reader.acceptShare(invitation: metadata)
            let accepted = try CloudKitWorkspaceContextRules.participantContext(
                from: facts, accountRecordName: accountRecordName, containerIdentifier: containerIdentifier, verifiedAt: now())
            var contexts = try file.contexts(accountRecordName: accountRecordName)
            let key = CloudKitWorkspaceContextKey(accepted)
            if let existing = contexts.first(where: { CloudKitWorkspaceContextKey($0) == key }), CloudAccountContextMatcher.sameScope(existing, accepted) {
                return existing
            }
            contexts.removeAll { CloudKitWorkspaceContextKey($0) == key }
            contexts.append(accepted)
            try file.persist(contexts, accountRecordName: accountRecordName)
            return accepted
        }

        public func refreshedContext(for context: AccountContext, accountRecordName: String) async throws -> AccountContext? {
            guard context.namespace.cloudKitAccountRecordName == accountRecordName, context.namespace.containerIdentifier == containerIdentifier else {
                return nil
            }
            let key = CloudKitWorkspaceContextKey(context)
            guard try file.contexts(accountRecordName: accountRecordName).contains(where: { CloudKitWorkspaceContextKey($0) == key }) else { return nil }
            guard let facts = try await reader.membership(of: context) else {
                try forget(key, accountRecordName: accountRecordName)
                return nil
            }
            guard let refreshed = CloudKitWorkspaceContextRules.refreshed(context, facts: facts, now: now()) else {
                try forget(key, accountRecordName: accountRecordName)
                return nil
            }
            try remember(refreshed, accountRecordName: accountRecordName)
            return refreshed
        }

        /// Drops the owner's cached share record name after the share was deleted.
        public func revokeCachedShare(owner: AccountContext, shareRecordName: String) async throws {
            try CloudKitWorkspaceContextRules.validateOwner(owner, containerIdentifier: containerIdentifier)
            let accountRecordName = owner.namespace.cloudKitAccountRecordName
            let key = CloudKitWorkspaceContextKey(owner)
            var contexts = try file.contexts(accountRecordName: accountRecordName)
            guard let index = contexts.firstIndex(where: { CloudKitWorkspaceContextKey($0) == key }) else { throw CloudKitWorkspaceError.unknownContext }
            guard contexts[index].shareRecordName == shareRecordName else { throw CloudKitWorkspaceError.shareRecordMismatch }
            contexts[index] = AccountContext(
                namespace: owner.namespace, databaseScope: .ownerPrivate, sharePermission: .owner, shareRecordName: nil, verifiedAt: now())
            try file.persist(contexts, accountRecordName: accountRecordName)
        }

        /// Persists `context` only when its scope differs from the stored one, so an
        /// unchanged refresh performs no write.
        private func remember(_ context: AccountContext, accountRecordName: String) throws {
            var contexts = try file.contexts(accountRecordName: accountRecordName)
            let key = CloudKitWorkspaceContextKey(context)
            guard let index = contexts.firstIndex(where: { CloudKitWorkspaceContextKey($0) == key }) else { throw CloudKitWorkspaceError.unknownContext }
            guard !CloudAccountContextMatcher.sameScope(contexts[index], context) else { return }
            contexts[index] = context
            try file.persist(contexts, accountRecordName: accountRecordName)
        }

        /// A definitively gone membership is removed, so it cannot be refreshed again.
        private func forget(_ key: CloudKitWorkspaceContextKey, accountRecordName: String) throws {
            var contexts = try file.contexts(accountRecordName: accountRecordName)
            contexts.removeAll { CloudKitWorkspaceContextKey($0) == key }
            try file.persist(contexts, accountRecordName: accountRecordName)
        }
    }

#endif
