#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel

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
        case missingDeletionIdentity(String)
        case duplicateRecordName(String)
        case identityIndexFailure
        case invalidRemoteAsset(ResourceKey)
        case unknownEvent
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
            await owner?.receive(event)
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
