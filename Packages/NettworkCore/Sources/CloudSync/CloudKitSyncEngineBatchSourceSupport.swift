#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, watchOS 10.0, *)
    public enum CloudKitSyncEngineBatchSourceError: Error, Hashable, Sendable {
        case invalidIdentityIndexLimit
        case invalidBatchAdmissionLimit
        case batchAdmissionLimitExceeded
        case bindingMismatch
        case persistedStateMismatch
        case fetchedStateAwaitingMirrorCommit
        case overlappingFetch
        case fetchFinishedWithoutDelegateCompletion
        case missingPostFetchState
        case accountChanged
        case workspaceZoneDeleted
        case unexpectedZone(String)
        case recordZoneFetchFailed
        case invalidStateSerialization
        case invalidRemoteIdentity
        case duplicateRecordName(String)
        case identityIndexFailure
        case invalidRemoteAsset(ResourceKey)
        case unknownEvent
    }

    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, watchOS 10.0, *)
    extension CloudKitSyncEngineBatchSourceError {
        /// No identity means the record was created and deleted between change tokens, so nothing local needs a
        /// tombstone and the deletion is skipped (nil). A stored identity that does not match the deletion fails closed.
        static func validatedDeletionIdentity(
            _ identity: CloudRecordNameIdentity?, recordName: String, recordType: String, namespace: PersistenceNamespace
        ) throws -> CloudRecordNameIdentity? {
            guard let identity else { return nil }
            guard identity.recordName == recordName, identity.recordType == recordType,
                identity.recordName == CloudRecordNaming.recordName(for: identity.resourceKey, workspaceID: namespace.workspaceID)
            else { throw invalidRemoteIdentity }
            return identity
        }
    }

    /// Failure bookkeeping for one batch source. Account changes, a deleted
    /// workspace zone, and foreign-zone deliveries stay terminal for the bound
    /// namespace; every other failure is retryable but forces the engine to be
    /// rebuilt from the last durably applied state, so changes the failed fetch
    /// advanced past in memory are fetched again instead of being skipped.
    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, watchOS 10.0, *)
    struct CloudKitBatchSourceFailureState: Sendable {
        private(set) var terminalFailure: CloudKitSyncEngineBatchSourceError?
        private(set) var requiresEngineRestart = false

        static func isTerminal(_ error: CloudKitSyncEngineBatchSourceError) -> Bool {
            switch error {
            case .accountChanged, .workspaceZoneDeleted, .unexpectedZone: true
            default: false
            }
        }

        mutating func record(_ error: CloudKitSyncEngineBatchSourceError) {
            if terminalFailure == nil, Self.isTerminal(error) { terminalFailure = error }
            requiresEngineRestart = true
        }

        mutating func requireEngineRestart() { requiresEngineRestart = true }

        mutating func engineRestarted() { requiresEngineRestart = false }

        func throwIfTerminal() throws {
            if let terminalFailure { throw terminalFailure }
        }
    }

    /// Fetched-but-uncommitted engine states per namespace. A later fetch is
    /// refused while one is pending; only the mirror acknowledgement or an
    /// explicit discard of that exact state releases it.
    struct CloudKitPendingFetchedStates: Sendable {
        private var stateByNamespace: [PersistenceNamespace: Data] = [:]

        func pendingState(in namespace: PersistenceNamespace) -> Data? { stateByNamespace[namespace] }

        mutating func record(_ state: Data, in namespace: PersistenceNamespace) throws {
            guard stateByNamespace[namespace] == nil else {
                throw CloudKitSyncEngineStateError.fetchedStateAwaitingMirrorCommit(namespace)
            }
            stateByNamespace[namespace] = state
        }

        func requireNoPendingState(in namespace: PersistenceNamespace) throws {
            guard stateByNamespace[namespace] == nil else {
                throw CloudKitSyncEngineStateError.fetchedStateAwaitingMirrorCommit(namespace)
            }
        }

        func requirePendingState(_ state: Data, in namespace: PersistenceNamespace) throws {
            guard stateByNamespace[namespace] == state else {
                throw CloudKitSyncEngineStateError.appliedStateDoesNotMatchFetchedState(namespace)
            }
        }

        mutating func acknowledge(_ state: Data, in namespace: PersistenceNamespace) {
            if stateByNamespace[namespace] == state { stateByNamespace[namespace] = nil }
        }

        /// Returns whether `state` was the pending state and has been released.
        mutating func discard(_ state: Data, in namespace: PersistenceNamespace) -> Bool {
            guard stateByNamespace[namespace] == state else { return false }
            stateByNamespace[namespace] = nil
            return true
        }
    }

    struct CloudKitFetchAdmission: Sendable {
        let maximumRecords: Int
        let maximumBytes: Int
        private(set) var recordCount = 0
        private(set) var byteCount = 0

        init(maximumRecords: Int, maximumBytes: Int) throws {
            guard maximumRecords > 0, maximumBytes > 0 else {
                throw CloudKitSyncEngineBatchSourceError.invalidBatchAdmissionLimit
            }
            self.maximumRecords = maximumRecords
            self.maximumBytes = maximumBytes
        }

        mutating func admit(byteCounts: [Int]) throws {
            guard recordCount < maximumRecords else {
                throw CloudKitSyncEngineBatchSourceError.batchAdmissionLimitExceeded
            }
            var nextBytes = byteCount
            for count in byteCounts {
                guard count >= 0, count <= maximumBytes - nextBytes else {
                    throw CloudKitSyncEngineBatchSourceError.batchAdmissionLimitExceeded
                }
                nextBytes += count
            }
            recordCount += 1
            byteCount = nextBytes
        }
    }

    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, watchOS 10.0, *)
    final class CloudKitSyncEngineBatchSourceDelegate: CKSyncEngineDelegate, @unchecked Sendable {
        private weak var owner: CloudKitSyncEngineBatchSourceAdapter?

        func install(owner: CloudKitSyncEngineBatchSourceAdapter) {
            self.owner = owner
        }

        func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
            await owner?.receive(event, from: syncEngine)
        }

        func nextRecordZoneChangeBatch(
            _ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine
        ) async -> CKSyncEngine.RecordZoneChangeBatch? {
            nil
        }

        func nextFetchChangesOptions(
            _ context: CKSyncEngine.FetchChangesContext, syncEngine: CKSyncEngine
        ) async -> CKSyncEngine.FetchChangesOptions {
            let zoneID = await owner?.configuredZoneID ?? CKRecordZone.ID(zoneName: "__invalid__")
            return .init(scope: .zoneIDs([zoneID]))
        }
    }

    @available(iOS 17.0, macOS 14.0, macCatalyst 17.0, tvOS 17.0, watchOS 10.0, *)
    enum CloudKitSyncEngineStateCodec {
        static func makeEngine(
            database: CKDatabase, persistedState: Data?, delegate: CloudKitSyncEngineBatchSourceDelegate, subscriptionID: CKSubscription.ID?
        ) throws -> CKSyncEngine {
            var configuration = CKSyncEngine.Configuration(database: database, stateSerialization: try decode(persistedState), delegate: delegate)
            configuration.automaticallySync = false
            configuration.subscriptionID = subscriptionID
            return CKSyncEngine(configuration)
        }

        static func decode(_ state: Data?) throws -> CKSyncEngine.State.Serialization? {
            try state.map { try PropertyListDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        }

        static func encode(_ state: CKSyncEngine.State.Serialization) throws -> Data {
            try PropertyListEncoder().encode(state)
        }
    }

    enum CloudKitRemoteResourceKey {
        static func decode(_ value: String) -> ResourceKey? {
            if let rawUUID = value.stripPrefix("object:"), let uuid = UUID(uuidString: rawUUID),
                uuid.uuidString.lowercased() == rawUUID
            {
                return .object(ObjectID(uuid))
            }
            if let rawValue = value.stripPrefix("string:"), !rawValue.isEmpty {
                return .string(rawValue)
            }
            return nil
        }
    }

    extension String {
        func stripPrefix(_ prefix: String) -> String? {
            guard hasPrefix(prefix) else { return nil }
            return String(dropFirst(prefix.count))
        }
    }
#endif
