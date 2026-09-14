#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    extension CloudKitRecordTransport {
        func commitConditionalMutation(_ mutation: AtomicCloudMutation) async throws {
            try AtomicCloudMutationValidator.validate(mutation)
            let temporaryAssets = CloudKitTemporaryAssetFiles()
            defer { temporaryAssets.cleanup() }
            let records = try materializedRecords(for: mutation, temporaryAssets: temporaryAssets)
            try await modifyAtomically(records, in: CloudKitProductionBoundary.database(in: container, account: account))
        }

        func conditionalResult(
            for error: Error, mutation: AtomicCloudMutation
        ) -> CloudConditionalBatchResult {
            let resourceKeys = Set(mutation.records.map(\.resourceKey))
            if isServerRecordChanged(error) { return .conflict }
            if isIndeterminateNetworkError(error) {
                return .indeterminate(failure(for: error, resourceKeys: resourceKeys))
            }
            if let adapterError = error as? CloudKitAdapterError {
                return .permanent(SyncFailure(category: .validation, message: String(describing: adapterError), resourceKeys: resourceKeys))
            }
            return conditionalTerminalResult(for: failure(for: error, resourceKeys: resourceKeys))
        }

        private func conditionalTerminalResult(for failure: SyncFailure) -> CloudConditionalBatchResult {
            switch failure.category {
            case .network, .rateLimited, .quotaExceeded, .accountUnavailable: return .retryable(failure)
            case .permissionDenied, .validation, .conflict, .malformedRemoteRecord, .security, .unknown:
                return .permanent(failure)
            }
        }

        func isValidStagedTransferGCMutation(_ mutation: CloudStagedTransferGCMutation) -> Bool {
            guard mutation.workspaceZone == account.namespace.workspaceZone else { return false }
            guard mutation.records.count <= 2 else { return false }
            guard mutation.recordNamesToDelete.count <= CloudStagedTransferGarbageCollector.maximumDeleteMembersPerPage else { return false }
            guard mutation.records.count + mutation.recordNamesToDelete.count <= AtomicCloudMutation.maximumBusinessRecordsPerOperation else { return false }
            guard Set(mutation.recordNamesToDelete).count == mutation.recordNamesToDelete.count else { return false }
            return Set(mutation.records.map(\.recordName)).isDisjoint(with: Set(mutation.recordNamesToDelete))
        }

        func commitStagedTransferGC(_ mutation: CloudStagedTransferGCMutation) async throws {
            let atomic = AtomicCloudMutation(
                operationID: mutation.operationID,
                workspaceZone: mutation.workspaceZone, records: mutation.records,
                preconditions: mutation.preconditions)
            try AtomicCloudMutationValidator.validate(atomic)
            try await validateExactDeletionPreconditions(mutation.deletionPreconditions, in: mutation.workspaceZone)
            let temporaryAssets = CloudKitTemporaryAssetFiles()
            defer { temporaryAssets.cleanup() }
            let records = try materializedRecords(for: atomic, temporaryAssets: temporaryAssets)
            let recordIDs = mutation.recordNamesToDelete.map {
                CKRecord.ID(recordName: $0, zoneID: CloudKitProductionBoundary.zoneID(for: mutation.workspaceZone))
            }
            try await modifyAtomically(
                records, deleting: recordIDs,
                in: CloudKitProductionBoundary.database(in: container, account: account))
        }

        func stagedTransferGCResult(for error: Error) -> CloudStagedTransferGCResult {
            if isServerRecordChanged(error) { return .conflict }
            if isIndeterminateNetworkError(error) {
                return .indeterminate(failure(for: error, resourceKeys: []))
            }
            return stagedTransferGCTerminalResult(for: failure(for: error, resourceKeys: []))
        }

        private func stagedTransferGCTerminalResult(for failure: SyncFailure) -> CloudStagedTransferGCResult {
            switch failure.category {
            case .network, .rateLimited, .quotaExceeded, .accountUnavailable: return .retryable(failure)
            case .permissionDenied, .validation, .conflict, .malformedRemoteRecord, .security, .unknown:
                return .permanent(failure)
            }
        }

        private func isServerRecordChanged(_ error: Error) -> Bool {
            (error as? CKError)?.code == .serverRecordChanged
        }

        private func isIndeterminateNetworkError(_ error: Error) -> Bool {
            guard let cloudError = error as? CKError else { return false }
            switch cloudError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable: return true
            default: return false
            }
        }

        private func materializedRecords(
            for mutation: AtomicCloudMutation,
            temporaryAssets: CloudKitTemporaryAssetFiles
        ) throws -> [CKRecord] {
            try mutation.records.map {
                try makeRecord(envelope: $0, mutation: mutation, temporaryAssets: temporaryAssets)
            }
        }

        func makeRecord(
            envelope: CloudRecordEnvelope, mutation: AtomicCloudMutation,
            temporaryAssets: CloudKitTemporaryAssetFiles
        ) throws -> CKRecord {
            let precondition = mutation.preconditions.first { $0.recordName == envelope.recordName }
            guard let precondition else { throw CloudKitAdapterError.conditionalWriteFailed("missing precondition") }
            switch envelope.writeMode {
            case .assertionPreserving: return try assertionPreservingRecord(envelope, precondition: precondition)
            case .businessSave:
                return try businessRecord(envelope, precondition: precondition, temporaryAssets: temporaryAssets)
            }
        }

        private func assertionPreservingRecord(
            _ envelope: CloudRecordEnvelope,
            precondition: CloudRecordPrecondition
        ) throws -> CKRecord {
            let expectedVisibility = try CloudDeterministicCoding.encode(envelope.visibility)
            guard case let .exact(_, systemFields, changeTag) = precondition,
                let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: systemFields),
                restored.recordType == envelope.recordType,
                restored.recordID == CloudKitProductionBoundary.recordID(for: envelope, namespace: account.namespace),
                restored.recordChangeTag == changeTag, restored["payload"] as? Data == envelope.payload,
                (restored["schemaVersion"] as? NSNumber)?.intValue == envelope.schemaVersion,
                restored["resourceKey"] as? String == envelope.resourceKey.description,
                restored["workspaceID"] as? String == envelope.workspaceID.description,
                (restored["isDeleted"] as? NSNumber)?.boolValue == envelope.isDeleted,
                restored["visibility"] as? Data == expectedVisibility
            else {
                throw CloudKitAdapterError.invalidSystemFields(envelope.resourceKey)
            }
            return restored
        }

        private func businessRecord(
            _ envelope: CloudRecordEnvelope, precondition: CloudRecordPrecondition,
            temporaryAssets: CloudKitTemporaryAssetFiles
        ) throws -> CKRecord {
            let record = try recordForBusinessSave(envelope, precondition: precondition)
            try populateBusinessFields(record, from: envelope)
            try populateAsset(record, from: envelope, temporaryAssets: temporaryAssets)
            return record
        }

        private func recordForBusinessSave(
            _ envelope: CloudRecordEnvelope, precondition: CloudRecordPrecondition
        ) throws -> CKRecord {
            switch precondition {
            case .mustNotExist:
                return CKRecord(recordType: envelope.recordType, recordID: CloudKitProductionBoundary.recordID(for: envelope, namespace: account.namespace))
            case let .exact(_, systemFields, changeTag):
                guard let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: systemFields),
                    restored.recordID == CloudKitProductionBoundary.recordID(for: envelope, namespace: account.namespace),
                    restored.recordChangeTag == changeTag
                else {
                    throw CloudKitAdapterError.invalidSystemFields(envelope.resourceKey)
                }
                return restored
            }
        }

        private func populateBusinessFields(_ record: CKRecord, from envelope: CloudRecordEnvelope) throws {
            record["payload"] = envelope.payload as CKRecordValue
            record["schemaVersion"] = NSNumber(value: envelope.schemaVersion)
            record["resourceKey"] = envelope.resourceKey.description as CKRecordValue
            record["workspaceID"] = envelope.workspaceID.description as CKRecordValue
            record["isDeleted"] = NSNumber(value: envelope.isDeleted)
            record["visibility"] = try CloudDeterministicCoding.encode(envelope.visibility) as CKRecordValue
            populateStagedTransferID(record, visibility: envelope.visibility)
            populateSessionStatus(record, from: envelope)
        }

        private func populateStagedTransferID(_ record: CKRecord, visibility: WorkspaceRecordVisibility) {
            if case let .staged(transferID) = visibility {
                record[CloudKitProductionBoundary.stagedTransferIDFieldName] = transferID.description as CKRecordValue
            } else {
                record[CloudKitProductionBoundary.stagedTransferIDFieldName] = nil
            }
        }

        private func populateSessionStatus(_ record: CKRecord, from envelope: CloudRecordEnvelope) {
            guard envelope.recordType == CloudStagedTransferRecordType.session else {
                record[CloudKitProductionBoundary.sessionStatusFieldName] = nil
                return
            }
            guard let session = try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: envelope.payload) else {
                return
            }
            record[CloudKitProductionBoundary.sessionStatusFieldName] = session.status.rawValue as CKRecordValue
        }

        private func populateAsset(
            _ record: CKRecord, from envelope: CloudRecordEnvelope,
            temporaryAssets: CloudKitTemporaryAssetFiles
        ) throws {
            guard let asset = envelope.recordAsset else {
                clearAsset(from: record)
                return
            }
            guard !envelope.isDeleted else {
                throw CloudKitAdapterError.invalidRecordAsset(envelope.resourceKey)
            }
            let assetURL = try temporaryAssets.materialize(asset)
            record[asset.fieldName] = CKAsset(fileURL: assetURL)
            record[CloudKitProductionBoundary.assetMetadataFieldName] = try CloudDeterministicCoding.encode(asset.metadata) as CKRecordValue
        }

        private func clearAsset(from record: CKRecord) {
            if let encoded = record[CloudKitProductionBoundary.assetMetadataFieldName] as? Data,
                let previous = try? CloudDeterministicCoding.decode(CloudRecordAssetMetadata.self, from: encoded)
            {
                record[previous.fieldName] = nil
            }
            record[CloudKitProductionBoundary.assetMetadataFieldName] = nil
        }

        func modifyAtomically(_ records: [CKRecord], deleting recordIDs: [CKRecord.ID] = [], in database: CKDatabase) async throws {
            try await withCheckedThrowingContinuation { continuation in
                let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: recordIDs)
                operation.savePolicy = .ifServerRecordUnchanged
                operation.isAtomic = true
                operation.modifyRecordsResultBlock = { result in continuation.resume(with: result) }
                database.add(operation)
            }
        }

        func queriedRecords(_ query: CKQuery, limit: Int, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> CloudKitQueryPage {
            try await withCheckedThrowingContinuation { continuation in
                let accumulator = CloudKitQueryAccumulator()
                let operation = CKQueryOperation(query: query)
                operation.zoneID = CloudKitProductionBoundary.zoneID(for: workspaceZone)
                operation.resultsLimit = limit
                operation.recordMatchedBlock = { _, result in
                    accumulator.consume(result)
                }
                operation.queryResultBlock = { result in
                    switch result {
                    case let .success(cursor):
                        continuation.resume(with: accumulator.result(isComplete: cursor == nil))
                    case let .failure(error): continuation.resume(throwing: error)
                    }
                }
                CloudKitProductionBoundary.database(in: container, account: account).add(operation)
            }
        }

        func exactSnapshot(_ record: CKRecord, resourceKey: ResourceKey, in workspaceZone: AuthoritativeWorkspaceZone) throws -> CloudExactRecordSnapshot {
            guard let payload = record["payload"] as? Data,
                record["resourceKey"] as? String == resourceKey.description,
                record["workspaceID"] as? String == workspaceZone.workspaceID.description,
                (record["isDeleted"] as? NSNumber)?.boolValue == false,
                let schemaVersion = (record["schemaVersion"] as? NSNumber)?.intValue,
                let changeTag = record.recordChangeTag,
                let modifiedAt = record.modificationDate
            else { throw CloudStagedTransferGCError.malformedCandidate }
            let fields = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
            return CloudExactRecordSnapshot(
                workspaceZone: workspaceZone, resourceKey: resourceKey, recordType: record.recordType, schemaVersion: schemaVersion, payload: payload,
                exactPrecondition: ExactRecordPrecondition(systemFields: fields, changeTag: changeTag), serverModifiedAt: modifiedAt)
        }

        private func validateExactDeletionPreconditions(_ values: [String: ExactRecordPrecondition], in workspaceZone: AuthoritativeWorkspaceZone) async throws
        {
            // This is defense-in-depth only: CKModifyRecordsOperation deletes by
            // record ID without a per-delete CAS. The official-client protocol
            // fences physical member deletion atomically with abandoned-session
            // and empty-sentinel assertion saves (BLK-006).
            guard !values.isEmpty else { return }
            guard values.count <= CloudStagedTransferGarbageCollector.maximumDeleteMembersPerPage else {
                throw CloudKitAdapterError.conditionalWriteFailed("too many deletion preconditions")
            }
            let zoneID = CloudKitProductionBoundary.zoneID(for: workspaceZone)
            let recordIDs = values.keys.sorted().map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
            let fetched = try await fetchDeletionPreconditionRecords(
                recordIDs,
                in: CloudKitProductionBoundary.database(in: container, account: account))
            let expectedTags = Dictionary(
                uniqueKeysWithValues: recordIDs.compactMap { recordID in
                    values[recordID.recordName].map { (recordID, $0.changeTag) }
                })
            try CloudKitDeletionPreconditionValidator.validate(
                fetched, expectedChangeTags: expectedTags)
        }

        func failure(for error: Error, resourceKeys: Set<ResourceKey>) -> SyncFailure {
            guard let cloudError = error as? CKError else {
                return SyncFailure(category: .unknown, message: String(describing: error), resourceKeys: resourceKeys)
            }
            switch cloudError.code {
            case .networkUnavailable, .networkFailure, .serviceUnavailable:
                return SyncFailure(category: .network, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            case .requestRateLimited:
                return SyncFailure(
                    category: .rateLimited, message: cloudError.localizedDescription,
                    retryAfter: cloudError.retryAfterSeconds.map { Date.now.addingTimeInterval($0) }, resourceKeys: resourceKeys)
            case .quotaExceeded: return SyncFailure(category: .quotaExceeded, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            case .notAuthenticated: return SyncFailure(category: .accountUnavailable, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            case .permissionFailure: return SyncFailure(category: .permissionDenied, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            case .serverRecordChanged: return SyncFailure(category: .conflict, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            default: return SyncFailure(category: .unknown, message: cloudError.localizedDescription, resourceKeys: resourceKeys)
            }
        }

        func reconciliationCase(for mutation: AtomicCloudMutation, cloudError: CKError) -> ReconciliationCase {
            let recordsByName = Dictionary(uniqueKeysWithValues: mutation.records.map { ($0.recordName, $0) })
            var base: [ResourceKey: ReconciliationSnapshot] = [:]
            var intended: [ResourceKey: ReconciliationSnapshot] = [:]
            for envelope in mutation.records {
                if let precondition = mutation.preconditions.first(where: { $0.recordName == envelope.recordName }),
                    case let .exact(_, systemFields, changeTag) = precondition
                {
                    base[envelope.resourceKey] = ReconciliationSnapshot(
                        resourceKey: envelope.resourceKey, recordType: envelope.recordType, schemaVersion: envelope.schemaVersion, encodedRecord: nil,
                        systemFields: systemFields, changeTag: changeTag, isTombstone: false)
                }
                intended[envelope.resourceKey] = ReconciliationSnapshot(
                    resourceKey: envelope.resourceKey, recordType: envelope.recordType, schemaVersion: envelope.schemaVersion, encodedRecord: envelope.payload,
                    systemFields: envelope.systemFields, changeTag: envelope.changeTag, isTombstone: envelope.isDeleted)
            }
            var current: [ResourceKey: ReconciliationSnapshot] = [:]
            if let serverRecord = cloudError.userInfo[CKRecordChangedErrorServerRecordKey] as? CKRecord,
                let envelope = recordsByName[serverRecord.recordID.recordName]
            {
                let archivedFields = try? NSKeyedArchiver.archivedData(withRootObject: serverRecord, requiringSecureCoding: true)
                current[envelope.resourceKey] = ReconciliationSnapshot(
                    resourceKey: envelope.resourceKey, recordType: serverRecord.recordType,
                    schemaVersion: (serverRecord["schemaVersion"] as? NSNumber)?.intValue ?? envelope.schemaVersion,
                    encodedRecord: serverRecord["payload"] as? Data, systemFields: archivedFields,
                    changeTag: serverRecord.recordChangeTag, isTombstone: (serverRecord["isDeleted"] as? NSNumber)?.boolValue ?? false)
            }
            return ReconciliationCase(
                namespace: account.namespace, operationID: mutation.operationID, resourceKeys: Set(mutation.records.map(\.resourceKey)),
                reason: .serverRecordChanged, base: base, intended: intended, current: current)
        }
    }

    private final class CloudKitQueryAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var records: [CKRecord] = []
        private var firstError: Error?

        func consume(_ result: Result<CKRecord, Error>) {
            lock.lock()
            defer { lock.unlock() }
            guard firstError == nil else { return }
            switch result {
            case let .success(record): records.append(record)
            case let .failure(error): firstError = error
            }
        }

        func result(isComplete: Bool) -> Result<CloudKitQueryPage, Error> {
            lock.lock()
            defer { lock.unlock() }
            if let firstError { return .failure(firstError) }
            return .success(CloudKitQueryPage(records: records, isComplete: isComplete))
        }
    }

    struct CloudKitQueryPage: @unchecked Sendable {
        let records: [CKRecord]
        /// `false` means callers must not treat an empty result as exhaustive.
        let isComplete: Bool
    }

    private extension CloudRecordPrecondition {
        var recordName: String {
            switch self {
            case .mustNotExist(let recordName), .exact(let recordName, _, _): recordName
            }
        }
    }

#endif
