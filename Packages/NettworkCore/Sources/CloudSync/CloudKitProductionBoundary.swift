#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    /// Thin conditional bridge for the app target's configured CloudKit adapter.
    /// No container is created here: entitlement, account, share, and real-device
    /// authority remain explicit application composition responsibilities.
    public enum CloudKitProductionBoundary {
        public static let assetMetadataFieldName = "assetMetadata"
        /// These scalar fields are deployment query-index requirements. They are
        /// intentionally separate from encoded payloads so bounded GC can select
        /// only invisible staged members and stale transfer sessions.
        public static let stagedTransferIDFieldName = "stagedTransferID"
        public static let sessionStatusFieldName = "sessionStatus"
        /// Owner workspaces use the private database; share participants must use
        /// the shared database and the record IDs restored from system fields.
        public static func database(in container: CKContainer, account: AccountContext) -> CKDatabase {
            switch account.databaseScope {
            case .ownerPrivate: container.privateCloudDatabase
            case .participantShared: container.sharedCloudDatabase
            }
        }

        public static func zoneID(for workspaceZone: AuthoritativeWorkspaceZone) -> CKRecordZone.ID {
            CKRecordZone.ID(zoneName: workspaceZone.zoneName, ownerName: workspaceZone.zoneOwnerRecordName)
        }

        public static func zoneID(for namespace: PersistenceNamespace) -> CKRecordZone.ID {
            CKRecordZone.ID(zoneName: namespace.zoneName, ownerName: namespace.zoneOwnerRecordName)
        }

        /// Valid only for owner-created records. Participant adapters restore the
        /// authoritative record ID from `CloudRecordEnvelope.systemFields` instead.
        public static func recordID(for envelope: CloudRecordEnvelope, workspaceZone: AuthoritativeWorkspaceZone) -> CKRecord.ID {
            CKRecord.ID(recordName: envelope.recordName, zoneID: zoneID(for: workspaceZone))
        }

        public static func recordID(for envelope: CloudRecordEnvelope, namespace: PersistenceNamespace) -> CKRecord.ID {
            CKRecord.ID(recordName: envelope.recordName, zoneID: zoneID(for: namespace))
        }

        public static func savePolicy(for precondition: CloudRecordPrecondition) -> CKModifyRecordsOperation.RecordSavePolicy {
            switch precondition {
            case .mustNotExist, .exact: return .ifServerRecordUnchanged
            }
        }
    }

    /// Durable state and subscription ownership stay with the app's CKSyncEngine
    /// composition. The transport consumes a state snapshot and persists a newer
    /// one only after CloudMirrorStore commits the complete verified batch.
    public protocol CloudKitSyncEngineStateStore: Sendable {
        func persistedState(in namespace: PersistenceNamespace) async throws -> Data?
        func persistAppliedState(_ state: Data, in namespace: PersistenceNamespace) async throws
    }

    /// CKSyncEngine-facing adapter point. A live app implementation owns its
    /// CKSyncEngine instance, subscription setup, and delegate callbacks here;
    /// the CloudSync target remains testable without credentials or entitlements.
    public protocol CloudKitSyncEngineDriver: Sendable {
        func ensureSubscription(in database: CKDatabase, namespace: PersistenceNamespace) async throws
        func fetchChanges(in database: CKDatabase, namespace: PersistenceNamespace, persistedState: Data?) async throws -> CloudChangeBatch
    }

    /// The platform-specific `CKSyncEngine` delegate belongs behind this narrow
    /// source. Its implementation converts fetched records and its serialized
    /// engine state into a complete, verified `CloudChangeBatch`; it must not
    /// persist the returned state itself.
    ///
    /// This separate boundary keeps CloudSync independent of OS-version-specific
    /// `CKSyncEngine` callback shapes while giving production composition one
    /// concrete state owner. A source must be backed by the same database and
    /// namespace passed to it, and must return the exact serialized state produced
    /// by its CKSyncEngine callback.
    public protocol CloudKitSyncEngineBatchSource: Sendable {
        func ensureSubscription(in database: CKDatabase, namespace: PersistenceNamespace) async throws
        func fetchChanges(in database: CKDatabase, namespace: PersistenceNamespace, persistedState: Data?) async throws -> CloudChangeBatch
    }

    public enum CloudKitSyncEngineStateError: Error, Hashable, Sendable {
        case fetchedStateAwaitingMirrorCommit(PersistenceNamespace)
        case appliedStateDoesNotMatchFetchedState(PersistenceNamespace)
    }

    /// Concrete state integration for a `CKSyncEngine`-backed source. Compose this
    /// actor as both `CloudKitSyncEngineDriver` and `CloudKitSyncEngineStateStore`
    /// when constructing `CloudKitRecordTransport`.
    ///
    /// It has one deliberate failure mode: after a batch has been fetched, no
    /// later engine fetch is allowed until `CloudMirrorStore` has committed that
    /// exact state and `persistAppliedState` acknowledges it. This prevents an
    /// uncommitted engine cursor from being advanced or overwritten after a crash.
    public actor CloudKitStatefulSyncEngineDriver: CloudKitSyncEngineDriver, CloudKitSyncEngineStateStore {
        private let source: any CloudKitSyncEngineBatchSource
        private let durableState: any CloudKitSyncEngineStateStore
        private var pendingStateByNamespace: [PersistenceNamespace: Data] = [:]

        public init(source: any CloudKitSyncEngineBatchSource, durableState: any CloudKitSyncEngineStateStore) {
            self.source = source
            self.durableState = durableState
        }

        public func persistedState(in namespace: PersistenceNamespace) async throws -> Data? {
            try await durableState.persistedState(in: namespace)
        }

        public func ensureSubscription(in database: CKDatabase, namespace: PersistenceNamespace) async throws {
            try await source.ensureSubscription(in: database, namespace: namespace)
        }

        public func fetchChanges(in database: CKDatabase, namespace: PersistenceNamespace, persistedState: Data?) async throws -> CloudChangeBatch {
            guard pendingStateByNamespace[namespace] == nil else {
                throw CloudKitSyncEngineStateError.fetchedStateAwaitingMirrorCommit(namespace)
            }
            let batch = try await source.fetchChanges(in: database, namespace: namespace, persistedState: persistedState)
            pendingStateByNamespace[namespace] = batch.newState
            return batch
        }

        public func persistAppliedState(_ state: Data, in namespace: PersistenceNamespace) async throws {
            guard let pending = pendingStateByNamespace[namespace], pending == state else {
                throw CloudKitSyncEngineStateError.appliedStateDoesNotMatchFetchedState(namespace)
            }
            try await durableState.persistAppliedState(state, in: namespace)
            pendingStateByNamespace[namespace] = nil
        }
    }

    /// Resolves durable workspace/share contexts and performs share mutations.
    /// It is intentionally separate from CloudKitRecordTransport: a record-sync
    /// fake cannot manufacture a verified account or participant membership.
    public protocol CloudKitWorkspaceContextStore: Sendable {
        func ownerContext(workspaceID: ObjectID, containerIdentifier: String, accountRecordName: String) async throws -> AccountContext
        func acceptedShareContext(metadata: Data, accountRecordName: String) async throws -> AccountContext
        func refreshedContext(for context: AccountContext, accountRecordName: String) async throws -> AccountContext?
        func revokeCachedShare(owner: AccountContext, shareRecordName: String) async throws
    }

    public protocol CloudKitWorkspaceShareService: Sendable {
        func invite(in container: CKContainer, owner: AccountContext, participantRecordName: String, permission: WorkspaceSharePermission) async throws -> Data
        func revoke(in container: CKContainer, owner: AccountContext, shareRecordName: String) async throws
    }

    /// Creates the owner zone, workspace root, and zone-wide subscription before a
    /// context can be returned to application composition.
    public protocol CloudKitWorkspaceBootstrapper: Sendable {
        func createWorkspace(in container: CKContainer, context: AccountContext) async throws
    }

    public enum CloudKitAdapterError: Error, Hashable, Sendable {
        case conditionalWriteFailed(String)
        case invalidSystemFields(ResourceKey)
        case receiptPayloadMissing
        case invalidRecordAsset(ResourceKey)
    }

    /// CKAsset only retains a file URL. This owner keeps each materialized file
    /// alive until the operation completion callback has fired, then removes every
    /// file on success, conflict, cancellation, and all thrown failure paths.
    final class CloudKitTemporaryAssetFiles {
        private var urls = [URL]()

        deinit { cleanup() }

        func materialize(_ asset: CloudRecordAssetDescriptor) throws -> URL {
            let bytes = try asset.validatedBytes()
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("nettwork-ckasset-\(UUID().uuidString)", isDirectory: false)
            do {
                try bytes.write(to: url, options: .atomic)
                urls.append(url)
                return url
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }

        func cleanup() {
            for url in urls { try? FileManager.default.removeItem(at: url) }
            urls.removeAll()
        }
    }

#endif
