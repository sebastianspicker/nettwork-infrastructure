#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    /// Creates the owner's workspace in the private database: the custom zone
    /// `nettwork.workspace.<workspaceID>`, the bootstrap sentinel and the
    /// zone-wide `CKShare`. Re-running finds existing ones and creates only what
    /// is missing; an existing sentinel of another workspace throws.
    public struct ProductionCloudKitWorkspaceBootstrapper: CloudKitWorkspaceBootstrapper {
        private let makeDatabase: @Sendable (CKContainer) -> any CloudKitWorkspaceBootstrapDatabase

        public init() {
            self.init { CloudKitPrivateWorkspaceDatabase(container: $0) }
        }

        init(makeDatabase: @escaping @Sendable (CKContainer) -> any CloudKitWorkspaceBootstrapDatabase) {
            self.makeDatabase = makeDatabase
        }

        public func createWorkspace(in container: CKContainer, context: AccountContext) async throws {
            try await Self.createWorkspace(using: makeDatabase(container), containerIdentifier: container.containerIdentifier, context: context)
        }

        static func createWorkspace(
            using database: any CloudKitWorkspaceBootstrapDatabase, containerIdentifier: String?, context: AccountContext
        ) async throws {
            try CloudKitWorkspaceContextRules.validateOwner(context, containerIdentifier: containerIdentifier)
            try await CloudKitWorkspaceBootstrap.run(zone: context.namespace.workspaceZone, database: database)
        }
    }

    /// Owner-only share mutations on the workspace's single zone-wide share.
    /// `invite` returns the share URL as UTF-8 bytes for the platform handoff;
    /// `revoke` deletes the share, which ends every participant's access.
    public struct ProductionCloudKitWorkspaceShareService: CloudKitWorkspaceShareService {
        private let makeWriter: @Sendable (CKContainer) -> any CloudKitWorkspaceShareWriting

        public init() {
            self.init { CloudKitPrivateWorkspaceDatabase(container: $0) }
        }

        init(makeWriter: @escaping @Sendable (CKContainer) -> any CloudKitWorkspaceShareWriting) {
            self.makeWriter = makeWriter
        }

        public func invite(in container: CKContainer, owner: AccountContext, participantRecordName: String, permission: WorkspaceSharePermission)
            async throws -> Data
        {
            try await Self.invite(
                using: makeWriter(container), containerIdentifier: container.containerIdentifier, owner: owner,
                participantRecordName: participantRecordName, permission: permission)
        }

        public func revoke(in container: CKContainer, owner: AccountContext, shareRecordName: String) async throws {
            try await Self.revoke(
                using: makeWriter(container), containerIdentifier: container.containerIdentifier, owner: owner, shareRecordName: shareRecordName)
        }

        static func invite(
            using writer: any CloudKitWorkspaceShareWriting, containerIdentifier: String?, owner: AccountContext, participantRecordName: String,
            permission: WorkspaceSharePermission
        ) async throws -> Data {
            try CloudKitWorkspaceContextRules.validateOwner(owner, containerIdentifier: containerIdentifier)
            guard CloudKitWorkspaceContextRules.isValidRecordName(participantRecordName),
                participantRecordName != owner.namespace.cloudKitAccountRecordName, CloudKitWorkspaceContextRules.isParticipantPermission(permission)
            else { throw CloudKitWorkspaceError.invalidParticipant }
            let url = try await writer.addParticipant(recordName: participantRecordName, permission: permission, in: owner.namespace.workspaceZone)
            return try CloudKitShareInvitation.encode(shareURL: url)
        }

        static func revoke(
            using writer: any CloudKitWorkspaceShareWriting, containerIdentifier: String?, owner: AccountContext, shareRecordName: String
        ) async throws {
            try CloudKitWorkspaceContextRules.validateOwner(owner, containerIdentifier: containerIdentifier)
            guard shareRecordName == CKRecordNameZoneWideShare else { throw CloudKitWorkspaceError.shareRecordMismatch }
            try await writer.deleteZoneShare(in: owner.namespace.workspaceZone)
        }
    }

#endif
