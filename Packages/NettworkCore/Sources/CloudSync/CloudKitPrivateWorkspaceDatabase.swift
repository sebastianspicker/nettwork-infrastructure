#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    /// Live owner-side database steps: the custom workspace zone, the bootstrap
    /// sentinel and the single zone-wide `CKShare`, all in the private database.
    /// Every create uses `.ifServerRecordUnchanged`, so an existing record is
    /// reported as `.alreadyExists` and never overwritten.
    struct CloudKitPrivateWorkspaceDatabase: CloudKitWorkspaceBootstrapDatabase, CloudKitWorkspaceShareWriting {
        static let shareTitle = "Nettwork workspace"

        let container: CKContainer
        private var database: CKDatabase { container.privateCloudDatabase }

        func zoneExists(_ zone: AuthoritativeWorkspaceZone) async throws -> Bool {
            do {
                _ = try await database.recordZone(for: CloudKitProductionBoundary.zoneID(for: zone))
                return true
            } catch {
                if CloudKitWorkspaceErrorMapping.isMissing(error) { return false }
                throw CloudKitWorkspaceErrorMapping.mapped(error)
            }
        }

        func createZone(_ zone: AuthoritativeWorkspaceZone) async throws {
            let zoneID = CloudKitProductionBoundary.zoneID(for: zone)
            let results = try await CloudKitWorkspaceErrorMapping.perform {
                try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
            }
            guard let result = results.saveResults[zoneID] else { throw CloudKitWorkspaceError.requestFailed(code: CKError.Code.internalError.rawValue) }
            do { _ = try result.get() } catch { throw CloudKitWorkspaceErrorMapping.mapped(error) }
        }

        func sentinel(named recordName: String, in zone: AuthoritativeWorkspaceZone) async throws -> CloudKitWorkspaceSentinelSnapshot? {
            let recordID = CKRecord.ID(recordName: recordName, zoneID: CloudKitProductionBoundary.zoneID(for: zone))
            return try await CloudKitWorkspaceErrorMapping.existingRecord(recordID, in: database).map(Self.snapshot(of:))
        }

        func createSentinel(_ sentinel: CloudKitWorkspaceSentinel, in zone: AuthoritativeWorkspaceZone) async throws -> CloudKitCreateOutcome {
            try await createConditionally(Self.sentinelRecord(sentinel, zone: zone))
        }

        func zoneShareExists(in zone: AuthoritativeWorkspaceZone) async throws -> Bool {
            try await zoneShare(in: zone) != nil
        }

        func createZoneShare(in zone: AuthoritativeWorkspaceZone) async throws -> CloudKitCreateOutcome {
            try await createConditionally(Self.newZoneShare(in: zone))
        }

        func addParticipant(recordName: String, permission: WorkspaceSharePermission, in zone: AuthoritativeWorkspaceZone) async throws -> URL {
            let share = try await zoneShare(in: zone) ?? Self.newZoneShare(in: zone)
            let lookedUp = try await CloudKitWorkspaceErrorMapping.perform {
                try await container.shareParticipant(forUserRecordID: CKRecord.ID(recordName: recordName))
            }
            let existing = share.participants.first { $0.userIdentity.userRecordID?.recordName == recordName }
            guard existing?.role != .owner else { throw CloudKitWorkspaceError.invalidParticipant }
            let participant = existing ?? lookedUp
            participant.permission = permission == .readWrite ? .readWrite : .readOnly
            if existing == nil { share.addParticipant(participant) }
            let saved = try await save(share)
            guard let url = (saved as? CKShare)?.url else { throw CloudKitWorkspaceError.shareURLUnavailable }
            return url
        }

        func deleteZoneShare(in zone: AuthoritativeWorkspaceZone) async throws {
            let shareID = Self.zoneShareID(in: zone)
            do {
                let results = try await database.modifyRecords(saving: [], deleting: [shareID])
                guard let result = results.deleteResults[shareID] else {
                    throw CloudKitWorkspaceError.requestFailed(code: CKError.Code.internalError.rawValue)
                }
                try result.get()
            } catch {
                if CloudKitWorkspaceErrorMapping.isMissing(error) { return }
                throw CloudKitWorkspaceErrorMapping.mapped(error)
            }
        }

        private func zoneShare(in zone: AuthoritativeWorkspaceZone) async throws -> CKShare? {
            try await CloudKitWorkspaceErrorMapping.existingRecord(Self.zoneShareID(in: zone), in: database) as? CKShare
        }

        private func createConditionally(_ record: CKRecord) async throws -> CloudKitCreateOutcome {
            do {
                _ = try await save(record)
                return .created
            } catch CloudKitWorkspaceError.concurrentChange {
                return .alreadyExists
            }
        }

        /// Saves one record conditionally; a lost race surfaces as `.concurrentChange`.
        private func save(_ record: CKRecord) async throws -> CKRecord {
            do {
                let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
                guard let result = results.saveResults[record.recordID] else {
                    throw CloudKitWorkspaceError.requestFailed(code: CKError.Code.internalError.rawValue)
                }
                return try result.get()
            } catch {
                throw CloudKitWorkspaceErrorMapping.mapped(Self.itemError(error, recordID: record.recordID))
            }
        }

        /// Unwraps the record's own error from an operation-level partial failure.
        private static func itemError(_ error: Error, recordID: CKRecord.ID) -> Error {
            guard let cloudError = error as? CKError, cloudError.code == .partialFailure,
                let itemError = cloudError.partialErrorsByItemID?[recordID]
            else { return error }
            return itemError
        }

        static func zoneShareID(in zone: AuthoritativeWorkspaceZone) -> CKRecord.ID {
            CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: CloudKitProductionBoundary.zoneID(for: zone))
        }

        /// A zone-wide share with no public access; participants are added by invitation only.
        static func newZoneShare(in zone: AuthoritativeWorkspaceZone) -> CKShare {
            let share = CKShare(recordZoneID: CloudKitProductionBoundary.zoneID(for: zone))
            share.publicPermission = .none
            share[CKShare.SystemFieldKey.title] = shareTitle as CKRecordValue
            return share
        }

        /// The sentinel record with exactly the fields of a transport business save.
        static func sentinelRecord(_ sentinel: CloudKitWorkspaceSentinel, zone: AuthoritativeWorkspaceZone) -> CKRecord {
            let recordID = CKRecord.ID(recordName: sentinel.recordName, zoneID: CloudKitProductionBoundary.zoneID(for: zone))
            let record = CKRecord(recordType: sentinel.recordType, recordID: recordID)
            record["payload"] = sentinel.payload as CKRecordValue
            record["schemaVersion"] = NSNumber(value: sentinel.schemaVersion)
            record["resourceKey"] = sentinel.resourceKey as CKRecordValue
            record["workspaceID"] = sentinel.workspaceID as CKRecordValue
            record["isDeleted"] = NSNumber(value: false)
            record["visibility"] = sentinel.visibility as CKRecordValue
            return record
        }

        static func snapshot(of record: CKRecord) -> CloudKitWorkspaceSentinelSnapshot {
            CloudKitWorkspaceSentinelSnapshot(
                recordType: record.recordType, resourceKey: record["resourceKey"] as? String, workspaceID: record["workspaceID"] as? String,
                isDeleted: (record["isDeleted"] as? NSNumber)?.boolValue ?? false, payload: record["payload"] as? Data)
        }
    }

#endif
