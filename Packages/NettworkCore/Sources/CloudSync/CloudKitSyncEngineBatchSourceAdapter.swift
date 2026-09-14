#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    /// Static-only production adapter for a single verified CloudKit database,
    /// namespace, and initial engine state. It never writes engine state: callers
    /// persist `CloudChangeBatch.newState` only after their mirror transaction.
    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, watchOS 10.0, *)
    public actor CloudKitSyncEngineBatchSourceAdapter: CloudKitSyncEngineBatchSource {
        public static let defaultMaximumRecordNameIdentities = 300_000

        private struct ActiveFetch {
            let stateVersionAtStart: UInt64
            var didReceiveWillFetchChanges = false
            var latestState: Data?
            var recordsByResourceKey: [ResourceKey: CloudRecordEnvelope] = [:]
            var resourceKeyByRecordName: [String: ResourceKey] = [:]
            var didFetchChanges = false
            var failure: CloudKitSyncEngineBatchSourceError?
        }

        private let database: CKDatabase
        private let namespace: PersistenceNamespace
        private let zoneID: CKRecordZone.ID
        private let identityIndex: any CloudRecordNameIdentityIndex
        private let maximumRecordNameIdentities: Int
        private let delegate: CloudKitSyncEngineBatchSourceDelegate
        private let engine: CKSyncEngine
        private var confirmedPersistedState: Data?
        private var pendingMirrorState: Data?
        private var stateVersion: UInt64 = 0
        private var activeFetch: ActiveFetch?
        private var terminalFailure: CloudKitSyncEngineBatchSourceError?

        var configuredZoneID: CKRecordZone.ID { zoneID }

        /// The caller must create a new source when its database, namespace, or
        /// initial persisted state changes. `subscriptionID` is passed to the
        /// engine configuration; subscription delivery remains app composition.
        public init(
            database: CKDatabase, namespace: PersistenceNamespace, persistedState: Data?,
            identityIndex: any CloudRecordNameIdentityIndex,
            maximumRecordNameIdentities: Int = CloudKitSyncEngineBatchSourceAdapter.defaultMaximumRecordNameIdentities,
            subscriptionID: CKSubscription.ID? = nil
        ) throws {
            guard maximumRecordNameIdentities > 0 else {
                throw CloudKitSyncEngineBatchSourceError.invalidIdentityIndexLimit
            }
            let delegate = CloudKitSyncEngineBatchSourceDelegate()
            var configuration = CKSyncEngine.Configuration(
                database: database,
                stateSerialization: try CloudKitSyncEngineStateCodec.decode(persistedState), delegate: delegate)
            configuration.automaticallySync = false
            configuration.subscriptionID = subscriptionID

            self.database = database
            self.namespace = namespace
            self.zoneID = CloudKitProductionBoundary.zoneID(for: namespace)
            self.identityIndex = identityIndex
            self.maximumRecordNameIdentities = maximumRecordNameIdentities
            self.delegate = delegate
            self.engine = CKSyncEngine(configuration)
            self.confirmedPersistedState = persistedState
            delegate.install(owner: self)
        }

        /// CKSyncEngine owns the configured subscription ID. With automatic sync
        /// disabled this method only verifies that a caller has not crossed the
        /// source's database or namespace boundary before requesting a foreground
        /// fetch.
        public func ensureSubscription(in database: CKDatabase, namespace: PersistenceNamespace) async throws {
            try requireExactBinding(database: database, namespace: namespace)
            try throwIfTerminalFailure()
        }

        public func fetchChanges(
            in database: CKDatabase, namespace: PersistenceNamespace, persistedState: Data?
        ) async throws -> CloudChangeBatch {
            try requireExactBinding(database: database, namespace: namespace)
            try throwIfTerminalFailure()
            try acknowledgeAppliedStateIfPresent(persistedState)
            guard activeFetch == nil else { throw CloudKitSyncEngineBatchSourceError.overlappingFetch }
            guard persistedState == confirmedPersistedState else {
                throw CloudKitSyncEngineBatchSourceError.persistedStateMismatch
            }

            activeFetch = ActiveFetch(stateVersionAtStart: stateVersion)
            do {
                try await engine.fetchChanges(.init(scope: .zoneIDs([zoneID])))
            } catch {
                activeFetch = nil
                throw error
            }

            guard let completedFetch = activeFetch else {
                throw CloudKitSyncEngineBatchSourceError.fetchFinishedWithoutDelegateCompletion
            }
            activeFetch = nil
            if let failure = completedFetch.failure { throw failure }
            guard completedFetch.didFetchChanges else {
                throw CloudKitSyncEngineBatchSourceError.fetchFinishedWithoutDelegateCompletion
            }
            guard completedFetch.stateVersionAtStart < stateVersion,
                let latestState = completedFetch.latestState
            else {
                throw CloudKitSyncEngineBatchSourceError.missingPostFetchState
            }

            let records = completedFetch.recordsByResourceKey.values.sorted { $0.recordName < $1.recordName }
            pendingMirrorState = latestState
            return CloudChangeBatch(records: records, newState: latestState)
        }

        func receive(_ event: CKSyncEngine.Event) async {
            switch event {
            case .fetchedDatabaseChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .fetchedRecordZoneChanges:
                await receiveRecordFetchEvent(event)
            case .stateUpdate, .didFetchChanges, .willFetchChanges:
                receiveStateEvent(event)
            case .accountChange:
                failClosed(.accountChanged)
            case .sentDatabaseChanges, .sentRecordZoneChanges, .willSendChanges, .didSendChanges:
                break
            @unknown default:
                failClosed(.unknownEvent)
            }
        }

        private func receiveRecordFetchEvent(_ event: CKSyncEngine.Event) async {
            switch event {
            case let .fetchedDatabaseChanges(changes): receiveDatabaseChanges(changes)
            case let .willFetchRecordZoneChanges(change): receiveZoneFetchStart(change)
            case let .didFetchRecordZoneChanges(change): receiveZoneFetchCompletion(change)
            case let .fetchedRecordZoneChanges(changes): await collect(changes)
            default: failClosed(.unknownEvent)
            }
        }

        private func receiveStateEvent(_ event: CKSyncEngine.Event) {
            switch event {
            case let .stateUpdate(update): receiveStateUpdate(update)
            case .didFetchChanges: receiveFetchCompletion()
            case .willFetchChanges: receiveFetchStart()
            default: failClosed(.unknownEvent)
            }
        }

        private func receiveDatabaseChanges(_ changes: CKSyncEngine.Event.FetchedDatabaseChanges) {
            for modification in changes.modifications where modification.zoneID != zoneID { failClosed(.unexpectedZone(modification.zoneID.zoneName)) }
            for deletion in changes.deletions { failClosed(deletion.zoneID == zoneID ? .workspaceZoneDeleted : .unexpectedZone(deletion.zoneID.zoneName)) }
        }
        private func receiveZoneFetchStart(_ change: CKSyncEngine.Event.WillFetchRecordZoneChanges) {
            guard change.zoneID != zoneID else { return }
            failClosed(.unexpectedZone(change.zoneID.zoneName))
        }
        private func receiveZoneFetchCompletion(_ change: CKSyncEngine.Event.DidFetchRecordZoneChanges) {
            guard change.zoneID == zoneID else {
                failClosed(.unexpectedZone(change.zoneID.zoneName))
                return
            }
            if change.error != nil { failClosed(.recordZoneFetchFailed) }
        }
        private func receiveStateUpdate(_ update: CKSyncEngine.Event.StateUpdate) {
            guard let state = try? CloudKitSyncEngineStateCodec.encode(update.stateSerialization) else {
                failClosed(.invalidStateSerialization)
                return
            }
            stateVersion &+= 1
            guard var activeFetch, activeFetch.didReceiveWillFetchChanges else { return }
            activeFetch.latestState = state
            self.activeFetch = activeFetch
        }
        private func receiveFetchCompletion() {
            guard var activeFetch else { return }
            guard activeFetch.didReceiveWillFetchChanges else {
                failClosed(.fetchFinishedWithoutDelegateCompletion)
                return
            }
            activeFetch.didFetchChanges = true
            self.activeFetch = activeFetch
        }
        private func receiveFetchStart() {
            guard var activeFetch else { return }
            activeFetch.didReceiveWillFetchChanges = true
            self.activeFetch = activeFetch
        }
        private func collect(_ changes: CKSyncEngine.Event.FetchedRecordZoneChanges) async {
            guard activeFetch != nil else { return }
            do {
                for modification in changes.modifications {
                    try await collect(modification.record)
                }
                for deletion in changes.deletions {
                    try await collect(deletion)
                }
            } catch let error as CloudKitSyncEngineBatchSourceError {
                failClosed(error)
            } catch {
                failClosed(.identityIndexFailure)
            }
        }

        private func collect(_ record: CKRecord) async throws {
            guard record.recordID.zoneID == zoneID else {
                throw CloudKitSyncEngineBatchSourceError.unexpectedZone(record.recordID.zoneID.zoneName)
            }
            guard let workspaceID = record["workspaceID"] as? String,
                workspaceID == namespace.workspaceID.description,
                let encodedResourceKey = record["resourceKey"] as? String,
                let resourceKey = CloudKitRemoteResourceKey.decode(encodedResourceKey)
            else {
                throw CloudKitSyncEngineBatchSourceError.invalidRemoteIdentity
            }
            let recordName = record.recordID.recordName
            guard recordName == CloudRecordNaming.recordName(for: resourceKey, workspaceID: namespace.workspaceID) else {
                throw CloudKitSyncEngineBatchSourceError.invalidRemoteIdentity
            }

            let isDeleted = (record["isDeleted"] as? NSNumber)?.boolValue ?? false
            let recordAsset = try assetDescriptor(from: record, resourceKey: resourceKey, isDeleted: isDeleted)
            let systemFields = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
            let schemaVersion = (record["schemaVersion"] as? NSNumber)?.intValue ?? 0
            let changeTag = record.recordChangeTag ?? ""
            let envelope = CloudRecordEnvelope(
                recordName: recordName, resourceKey: resourceKey,
                workspaceID: namespace.workspaceID, recordType: record.recordType, schemaVersion: schemaVersion,
                payload: record["payload"] as? Data ?? Data(), recordAsset: recordAsset,
                systemFields: systemFields, changeTag: changeTag, isDeleted: isDeleted)
            let identity = CloudRecordNameIdentity(
                recordName: recordName, resourceKey: resourceKey,
                recordType: record.recordType, schemaVersion: schemaVersion, systemFields: systemFields,
                changeTag: changeTag)
            try await identityIndex.store(identity, in: namespace, maximumEntries: maximumRecordNameIdentities)
            try append(envelope)
        }

        private func collect(_ deletion: CKDatabase.RecordZoneChange.Deletion) async throws {
            guard deletion.recordID.zoneID == zoneID else {
                throw CloudKitSyncEngineBatchSourceError.unexpectedZone(deletion.recordID.zoneID.zoneName)
            }
            guard let identity = try await identityIndex.identity(for: deletion.recordID.recordName, in: namespace) else {
                throw CloudKitSyncEngineBatchSourceError.missingDeletionIdentity(deletion.recordID.recordName)
            }
            guard identity.recordName == deletion.recordID.recordName, identity.recordType == deletion.recordType,
                identity.recordName == CloudRecordNaming.recordName(for: identity.resourceKey, workspaceID: namespace.workspaceID)
            else {
                throw CloudKitSyncEngineBatchSourceError.invalidRemoteIdentity
            }
            try append(
                CloudRecordEnvelope(
                    recordName: identity.recordName, resourceKey: identity.resourceKey,
                    workspaceID: namespace.workspaceID, recordType: identity.recordType,
                    schemaVersion: identity.schemaVersion, payload: Data(), systemFields: identity.systemFields,
                    changeTag: identity.changeTag, isDeleted: true))
        }

        /// The metadata field is a compact record-bound capability, not an
        /// independently fetched object. Its bounded CKAsset bytes are converted
        /// to immutable transport data only after the declared SHA-256 matches.
        private func assetDescriptor(
            from record: CKRecord, resourceKey: ResourceKey, isDeleted: Bool
        ) throws -> CloudRecordAssetDescriptor? {
            let encodedMetadata = record[CloudKitProductionBoundary.assetMetadataFieldName] as? Data
            guard let encodedMetadata else { return nil }
            guard !isDeleted,
                let metadata = try? CloudDeterministicCoding.decode(CloudRecordAssetMetadata.self, from: encodedMetadata),
                let asset = record[metadata.fieldName] as? CKAsset, let url = asset.fileURL
            else {
                throw CloudKitSyncEngineBatchSourceError.invalidRemoteAsset(resourceKey)
            }
            let durable = try CloudRecordAssetDescriptor(metadata: metadata, storage: .durableFile(url))
            let bytes = try durable.validatedBytes()
            return try CloudRecordAssetDescriptor(metadata: metadata, storage: .inline(bytes))
        }

        private func append(_ envelope: CloudRecordEnvelope) throws {
            guard var activeFetch else { return }
            if let existing = activeFetch.resourceKeyByRecordName[envelope.recordName], existing != envelope.resourceKey {
                throw CloudKitSyncEngineBatchSourceError.duplicateRecordName(envelope.recordName)
            }
            activeFetch.resourceKeyByRecordName[envelope.recordName] = envelope.resourceKey
            activeFetch.recordsByResourceKey[envelope.resourceKey] = envelope
            self.activeFetch = activeFetch
        }

        private func acknowledgeAppliedStateIfPresent(_ persistedState: Data?) throws {
            guard let pendingMirrorState else { return }
            guard persistedState == pendingMirrorState else {
                throw CloudKitSyncEngineBatchSourceError.fetchedStateAwaitingMirrorCommit
            }
            confirmedPersistedState = pendingMirrorState
            self.pendingMirrorState = nil
        }

        private func requireExactBinding(database: CKDatabase, namespace: PersistenceNamespace) throws {
            guard database === self.database, namespace == self.namespace else {
                throw CloudKitSyncEngineBatchSourceError.bindingMismatch
            }
        }

        private func throwIfTerminalFailure() throws {
            if let terminalFailure { throw terminalFailure }
        }

        private func failClosed(_ error: CloudKitSyncEngineBatchSourceError) {
            if terminalFailure == nil { terminalFailure = error }
            if var activeFetch, activeFetch.failure == nil {
                activeFetch.failure = error
                self.activeFetch = activeFetch
            }
        }
    }

#endif
