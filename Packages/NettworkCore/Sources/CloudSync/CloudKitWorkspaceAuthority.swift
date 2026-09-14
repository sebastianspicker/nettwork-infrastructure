#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    /// Concrete authority boundary. The injected context/share services retain the
    /// app-specific persisted mapping between CloudKit share metadata and a full
    /// AccountContext; this type never invents one from unverified transport data.
    public actor CloudKitWorkspaceAuthority: CloudWorkspaceAuthority {
        private let container: CKContainer
        private let contextStore: any CloudKitWorkspaceContextStore
        private let shareService: any CloudKitWorkspaceShareService
        private let bootstrapper: any CloudKitWorkspaceBootstrapper

        public init(
            container: CKContainer, contextStore: any CloudKitWorkspaceContextStore, shareService: any CloudKitWorkspaceShareService,
            bootstrapper: any CloudKitWorkspaceBootstrapper
        ) {
            self.container = container
            self.contextStore = contextStore
            self.shareService = shareService
            self.bootstrapper = bootstrapper
        }

        public func currentAccount() async throws -> CloudAccountIdentity {
            do {
                let recordID = try await container.userRecordID()
                return CloudAccountIdentity(cloudKitUserRecordName: recordID.recordName, isAvailable: true)
            } catch { return CloudAccountIdentity(cloudKitUserRecordName: "", isAvailable: false) }
        }

        public func createWorkspace(workspaceID: ObjectID, containerIdentifier: String) async throws -> AccountContext {
            let recordID = try await container.userRecordID()
            let context = try await contextStore.ownerContext(
                workspaceID: workspaceID, containerIdentifier: containerIdentifier, accountRecordName: recordID.recordName)
            try await bootstrapper.createWorkspace(in: container, context: context)
            return context
        }

        public func inviteParticipant(owner: AccountContext, participantCloudKitUserRecordName: String, permission: WorkspaceSharePermission) async throws
            -> Data
        {
            try await shareService.invite(in: container, owner: owner, participantRecordName: participantCloudKitUserRecordName, permission: permission)
        }

        public func acceptShare(metadata: Data) async throws -> AccountContext {
            let recordID = try await container.userRecordID()
            return try await contextStore.acceptedShareContext(metadata: metadata, accountRecordName: recordID.recordName)
        }

        public func revokeShare(owner: AccountContext, shareRecordName: String) async throws {
            try await shareService.revoke(in: container, owner: owner, shareRecordName: shareRecordName)
            try await contextStore.revokeCachedShare(owner: owner, shareRecordName: shareRecordName)
        }

        public func verifyMembership(for context: AccountContext) async throws -> AccountContext? {
            let recordID = try await container.userRecordID()
            guard recordID.recordName == context.namespace.cloudKitAccountRecordName else { return nil }
            return try await contextStore.refreshedContext(for: context, accountRecordName: recordID.recordName)
        }
    }

#endif
