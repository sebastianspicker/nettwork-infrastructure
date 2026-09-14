#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    /// Concrete CloudKit transport. It routes account scope through the verified
    /// AccountContext, asks the CKSyncEngine driver for scoped changes, and writes
    /// every mutation with a single atomic conditional CKModifyRecordsOperation.
    public actor CloudKitRecordTransport: CloudRecordTransport, CloudConditionalBatchTransport, CloudReceiptLookupTransport, CloudExactRecordReading,
        CloudAppliedChangeStatePersisting, CloudStagedTransferGCTransport
    {
        let container: CKContainer
        let account: AccountContext
        let engine: any CloudKitSyncEngineDriver
        let stateStore: any CloudKitSyncEngineStateStore

        public init(container: CKContainer, account: AccountContext, engine: any CloudKitSyncEngineDriver, stateStore: any CloudKitSyncEngineStateStore) {
            self.container = container
            self.account = account
            self.engine = engine
            self.stateStore = stateStore
        }

        public func fetchChanges() async throws -> CloudChangeBatch {
            let database = CloudKitProductionBoundary.database(in: container, account: account)
            try await engine.ensureSubscription(in: database, namespace: account.namespace)
            let persistedState = try await stateStore.persistedState(in: account.namespace)
            return try await engine.fetchChanges(in: database, namespace: account.namespace, persistedState: persistedState)
        }

        public func persistAppliedChangeState(_ state: Data) async throws {
            try await stateStore.persistAppliedState(state, in: account.namespace)
        }

        public func saveAtomically(_ mutation: AtomicCloudMutation) async throws -> CloudSaveResult {
            guard mutation.workspaceZone == account.namespace.workspaceZone else {
                return .permanentFailure(SyncFailure(category: .security, message: "Atomic mutation escaped the verified workspace zone."))
            }
            do {
                try AtomicCloudMutationValidator.validate(mutation)
                let temporaryAssets = CloudKitTemporaryAssetFiles()
                defer { temporaryAssets.cleanup() }
                let records = try makeRecords(for: mutation, temporaryAssets: temporaryAssets)
                try await modifyAtomically(records, in: CloudKitProductionBoundary.database(in: container, account: account))
                guard let receipt = mutation.records.first(where: { $0.recordType == CloudRecordNaming.receiptRecordType }) else {
                    throw CloudKitAdapterError.receiptPayloadMissing
                }
                return .accepted(receipt: try CloudDeterministicCoding.decode(OperationReceipt.self, from: receipt.payload))
            } catch {
                return saveResult(for: error, mutation: mutation)
            }
        }

        private func makeRecords(
            for mutation: AtomicCloudMutation,
            temporaryAssets: CloudKitTemporaryAssetFiles
        ) throws -> [CKRecord] {
            var records: [CKRecord] = []
            records.reserveCapacity(mutation.records.count)
            for envelope in mutation.records {
                records.append(try makeRecord(envelope: envelope, mutation: mutation, temporaryAssets: temporaryAssets))
            }
            return records
        }

        private func saveResult(for error: any Error, mutation: AtomicCloudMutation) -> CloudSaveResult {
            if let cloudError = error as? CKError, cloudError.code == .serverRecordChanged {
                return .conflict(reconciliationCase(for: mutation, cloudError: cloudError))
            }
            let resourceKeys = Set(mutation.records.map(\.resourceKey))
            if let adapterError = error as? CloudKitAdapterError {
                return .permanentFailure(
                    SyncFailure(
                        category: .validation,
                        message: String(describing: adapterError),
                        resourceKeys: resourceKeys
                    ))
            }
            return saveResult(for: failure(for: error, resourceKeys: resourceKeys))
        }

        private func saveResult(for failure: SyncFailure) -> CloudSaveResult {
            switch failure.category {
            case .network, .rateLimited, .quotaExceeded, .accountUnavailable:
                return .retryableFailure(failure)
            case .permissionDenied, .validation, .conflict, .malformedRemoteRecord, .security, .unknown:
                return .permanentFailure(failure)
            }
        }

        /// Receipt-free bounded CAS transport for staged transfers. Callers must
        /// resolve `.indeterminate` by reading the deterministic session record;
        /// they must never blindly replay an uncertain append.
        public func saveConditionally(_ mutation: AtomicCloudMutation) async throws -> CloudConditionalBatchResult {
            guard mutation.workspaceZone == account.namespace.workspaceZone else {
                return .permanent(SyncFailure(category: .security, message: "Conditional mutation escaped the verified workspace zone."))
            }
            do {
                try await commitConditionalMutation(mutation)
                return .accepted
            } catch {
                return conditionalResult(for: error, mutation: mutation)
            }
        }

        public func stagedTransferSessions(olderThan: Date, limit: Int, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> [CloudExactRecordSnapshot]
        {
            guard workspaceZone == account.namespace.workspaceZone, limit > 0 else { return [] }
            let query = CKQuery(
                recordType: CloudStagedTransferRecordType.session,
                predicate: NSCompoundPredicate(andPredicateWithSubpredicates: [
                    NSPredicate(format: "workspaceID == %@", workspaceZone.workspaceID.description),
                    NSPredicate(
                        format: "%K IN %@", CloudKitProductionBoundary.sessionStatusFieldName,
                        [CloudStagedTransferStatus.staging.rawValue, CloudStagedTransferStatus.complete.rawValue, CloudStagedTransferStatus.abandoned.rawValue]),
                    NSPredicate(format: "modificationDate < %@", olderThan as NSDate),
                ]))
            query.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: true)]
            let page = try await queriedRecords(query, limit: limit, in: workspaceZone)
            let expectedZone = CloudKitProductionBoundary.zoneID(for: workspaceZone)
            let snapshots = try page.records.compactMap { record in
                guard let payload = record["payload"] as? Data,
                    let session = try? CloudDeterministicCoding.decode(CloudStagedTransferSession.self, from: payload),
                    (try? CloudDeterministicCoding.encode(session)) == payload,
                    record.recordID.zoneID == expectedZone,
                    record.recordID.recordName == CloudRecordNaming.recordName(for: session.resourceKey, workspaceID: workspaceZone.workspaceID),
                    record["resourceKey"] as? String == session.resourceKey.description,
                    record["workspaceID"] as? String == workspaceZone.workspaceID.description,
                    (record["schemaVersion"] as? NSNumber)?.intValue == CloudRecordNaming.schemaVersion,
                    (record["isDeleted"] as? NSNumber)?.boolValue == false,
                    record[CloudKitProductionBoundary.sessionStatusFieldName] as? String == session.status.rawValue
                else {
                    throw CloudStagedTransferGCError.malformedCandidate
                }
                return try exactSnapshot(record, resourceKey: session.resourceKey, in: workspaceZone)
            }
            return snapshots.sorted { lhs, rhs in
                lhs.serverModifiedAt == rhs.serverModifiedAt ? lhs.resourceKey < rhs.resourceKey : lhs.serverModifiedAt < rhs.serverModifiedAt
            }
        }

        public func stagedTransferMembers(transferID: ObjectID, limit: Int, in workspaceZone: AuthoritativeWorkspaceZone) async throws
            -> CloudStagedTransferGCMemberPage
        {
            guard workspaceZone == account.namespace.workspaceZone, (1...CloudStagedTransferGarbageCollector.maximumDeleteMembersPerPage).contains(limit) else {
                return CloudStagedTransferGCMemberPage(members: [], isComplete: false)
            }
            let predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
                NSPredicate(format: "workspaceID == %@", workspaceZone.workspaceID.description),
                NSPredicate(format: "%K == %@", CloudKitProductionBoundary.stagedTransferIDFieldName, transferID.description),
            ])
            var queried: [CKRecord] = []
            let recordTypes = CloudRecordNaming.domainRecordTypes.subtracting(CloudStagedTransferRecordType.infrastructure).sorted()
            for recordType in recordTypes {
                guard queried.count < limit else {
                    return try gcMemberPage(from: queried, transferID: transferID, workspaceZone: workspaceZone, isComplete: false)
                }
                let query = CKQuery(recordType: recordType, predicate: predicate)
                query.sortDescriptors = [NSSortDescriptor(key: "modificationDate", ascending: true)]
                let page = try await queriedRecords(query, limit: limit - queried.count, in: workspaceZone)
                queried.append(contentsOf: page.records)
                // Reaching the requested bound is deliberately incomplete even
                // when this record type's cursor is nil: a later type may still
                // hold staged members and session deletion must fail closed.
                if !page.isComplete || queried.count == limit {
                    return try gcMemberPage(from: queried, transferID: transferID, workspaceZone: workspaceZone, isComplete: false)
                }
            }
            return try gcMemberPage(from: queried, transferID: transferID, workspaceZone: workspaceZone, isComplete: true)
        }

        private func gcMemberPage(from records: [CKRecord], transferID: ObjectID, workspaceZone: AuthoritativeWorkspaceZone, isComplete: Bool) throws
            -> CloudStagedTransferGCMemberPage
        {
            let expectedZone = CloudKitProductionBoundary.zoneID(for: workspaceZone)
            let members = try records.sorted {
                let lhsDate = $0.modificationDate ?? .distantFuture
                let rhsDate = $1.modificationDate ?? .distantFuture
                return lhsDate == rhsDate ? $0.recordID.recordName < $1.recordID.recordName : lhsDate < rhsDate
            }.map { record in
                guard let resourceKey = record["resourceKey"] as? String,
                    !resourceKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    record.recordID.zoneID == expectedZone,
                    record.recordID.recordName == CloudRecordNaming.recordName(forResourceKeyDescription: resourceKey, workspaceID: workspaceZone.workspaceID),
                    CloudRecordNaming.domainRecordTypes.contains(record.recordType),
                    record.recordType != CloudStagedTransferRecordType.session,
                    record["workspaceID"] as? String == workspaceZone.workspaceID.description,
                    (record["schemaVersion"] as? NSNumber)?.intValue == CloudRecordNaming.schemaVersion,
                    let visibilityData = record["visibility"] as? Data,
                    let visibility = try? CloudDeterministicCoding.decode(WorkspaceRecordVisibility.self, from: visibilityData),
                    visibility == .staged(transferID: transferID),
                    record[CloudKitProductionBoundary.stagedTransferIDFieldName] as? String == transferID.description,
                    (record["isDeleted"] as? NSNumber)?.boolValue == false,
                    let changeTag = record.recordChangeTag,
                    !changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw CloudStagedTransferGCError.invalidMember
                }
                let fields = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
                guard let restored = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: fields),
                    restored.recordID == record.recordID,
                    restored.recordChangeTag == changeTag,
                    restored["resourceKey"] as? String == resourceKey,
                    restored["workspaceID"] as? String == workspaceZone.workspaceID.description,
                    restored[CloudKitProductionBoundary.stagedTransferIDFieldName] as? String == transferID.description
                else {
                    throw CloudStagedTransferGCError.invalidMember
                }
                return CloudStagedTransferGCMember(
                    recordName: record.recordID.recordName, resourceKeyDescription: resourceKey, recordType: record.recordType, workspaceZone: workspaceZone,
                    workspaceID: workspaceZone.workspaceID, visibility: visibility, stagedTransferID: transferID,
                    exactPrecondition: ExactRecordPrecondition(systemFields: fields, changeTag: changeTag))
            }
            return CloudStagedTransferGCMemberPage(members: members, isComplete: isComplete)
        }

        public func applyStagedTransferGC(_ mutation: CloudStagedTransferGCMutation) async throws -> CloudStagedTransferGCResult {
            guard isValidStagedTransferGCMutation(mutation) else {
                return .permanent(SyncFailure(category: .validation, message: "Invalid staged-transfer GC mutation."))
            }
            do {
                try await commitStagedTransferGC(mutation)
                return .accepted
            } catch {
                return stagedTransferGCResult(for: error)
            }
        }

        public func receipt(operationID: ObjectID, in workspaceZone: AuthoritativeWorkspaceZone) async throws -> OperationReceipt? {
            guard workspaceZone == account.namespace.workspaceZone else { return nil }
            let key = ResourceKey.operationReceipt(operationID: operationID)
            let recordID = CKRecord.ID(
                recordName: CloudRecordNaming.recordName(for: key, workspaceID: workspaceZone.workspaceID),
                zoneID: CloudKitProductionBoundary.zoneID(for: workspaceZone))
            do {
                let record = try await CloudKitProductionBoundary.database(in: container, account: account).record(for: recordID)
                guard let payload = record["payload"] as? Data else { return nil }
                return try CloudDeterministicCoding.decode(OperationReceipt.self, from: payload)
            } catch let error as CKError where error.code == .unknownItem { return nil }
        }

        public func exactRecord(
            for resourceKey: ResourceKey,
            in workspaceZone: AuthoritativeWorkspaceZone
        ) async throws -> CloudExactRecordSnapshot? {
            guard workspaceZone == account.namespace.workspaceZone else { return nil }
            let recordID = CKRecord.ID(
                recordName: CloudRecordNaming.recordName(for: resourceKey, workspaceID: workspaceZone.workspaceID),
                zoneID: CloudKitProductionBoundary.zoneID(for: workspaceZone)
            )
            do {
                let record = try await CloudKitProductionBoundary.database(in: container, account: account).record(for: recordID)
                guard let payload = record["payload"] as? Data,
                    record["resourceKey"] as? String == resourceKey.description,
                    record["workspaceID"] as? String == workspaceZone.workspaceID.description,
                    (record["isDeleted"] as? NSNumber)?.boolValue == false,
                    let schemaVersion = (record["schemaVersion"] as? NSNumber)?.intValue,
                    schemaVersion > 0,
                    let changeTag = record.recordChangeTag,
                    !changeTag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    let modifiedAt = record.modificationDate
                else {
                    throw CloudKitAdapterError.invalidSystemFields(resourceKey)
                }
                let archivedFields = try NSKeyedArchiver.archivedData(
                    withRootObject: record,
                    requiringSecureCoding: true
                )
                return CloudExactRecordSnapshot(
                    workspaceZone: workspaceZone,
                    resourceKey: resourceKey,
                    recordType: record.recordType,
                    schemaVersion: schemaVersion,
                    payload: payload,
                    exactPrecondition: ExactRecordPrecondition(systemFields: archivedFields, changeTag: changeTag),
                    serverModifiedAt: modifiedAt
                )
            } catch let error as CKError where error.code == .unknownItem {
                return nil
            }
        }
    }
#endif
