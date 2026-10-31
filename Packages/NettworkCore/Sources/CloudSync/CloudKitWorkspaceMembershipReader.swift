#if canImport(CloudKit)
    @preconcurrency import CloudKit
    import Foundation
    import NetworkModel
    import WorkspaceChangeControl

    /// Maps CloudKit failures of the workspace services. Offline and throttled
    /// failures become `CloudVerificationUnavailableError` through the shared
    /// classifier; every other CloudKit failure is a definitive typed error.
    enum CloudKitWorkspaceErrorMapping {
        static func isMissing(_ error: Error) -> Bool {
            guard let cloudError = error as? CKError else { return false }
            switch cloudError.code {
            case .unknownItem, .zoneNotFound, .userDeletedZone: return true
            default: return false
            }
        }

        static func isConflict(_ error: Error) -> Bool {
            (error as? CKError)?.code == .serverRecordChanged
        }

        static func mapped(_ error: Error) -> Error {
            if let transient = CloudKitVerificationFailureClassifier.transientFailure(for: error) { return transient }
            guard let cloudError = error as? CKError else { return error }
            switch cloudError.code {
            case .notAuthenticated, .accountTemporarilyUnavailable, .managedAccountRestricted: return CloudKitWorkspaceError.accountUnavailable
            case .permissionFailure, .participantMayNeedVerification: return CloudKitWorkspaceError.permissionDenied
            case .quotaExceeded: return CloudKitWorkspaceError.quotaExceeded
            case .serverRecordChanged: return CloudKitWorkspaceError.concurrentChange
            default: return CloudKitWorkspaceError.requestFailed(code: cloudError.errorCode)
            }
        }

        /// Runs one CloudKit request and rethrows its failure mapped.
        static func perform<Value: Sendable>(_ request: () async throws -> Value) async throws -> Value {
            do { return try await request() } catch { throw mapped(error) }
        }

        /// Fetches a record, returning `nil` only when CloudKit definitively reports it missing.
        static func existingRecord(_ recordID: CKRecord.ID, in database: CKDatabase) async throws -> CKRecord? {
            do {
                return try await database.record(for: recordID)
            } catch {
                if isMissing(error) { return nil }
                throw mapped(error)
            }
        }
    }

    extension CKShare.ParticipantPermission {
        var workspacePermission: WorkspaceSharePermission? {
            switch self {
            case .readOnly: .readOnly
            case .readWrite: .readWrite
            default: nil
            }
        }
    }

    /// Live membership reader. Owners are verified against the private database
    /// zone and its zone-wide share; participants against the shared database
    /// share and the current user's accepted participant entry.
    struct CloudKitContainerWorkspaceReader: CloudKitWorkspaceMembershipReading {
        let container: CKContainer

        func acceptShare(invitation: Data) async throws -> CloudKitAcceptedShareFacts {
            let metadata = try await shareMetadata(for: CloudKitShareInvitation.decode(invitation))
            let share = try await CloudKitWorkspaceErrorMapping.perform { try await container.accept(metadata) }
            let participant = share.currentUserParticipant
            return CloudKitAcceptedShareFacts(
                containerIdentifier: metadata.containerIdentifier, zoneName: share.recordID.zoneID.zoneName,
                zoneOwnerRecordName: share.recordID.zoneID.ownerName, shareRecordName: share.recordID.recordName,
                isZoneWide: metadata.hierarchicalRootRecordID == nil && share.recordID.recordName == CKRecordNameZoneWideShare,
                isAccepted: participant?.acceptanceStatus == .accepted, isOwnerRole: participant?.role == .owner,
                permission: participant?.permission.workspacePermission)
        }

        func membership(of context: AccountContext) async throws -> CloudKitWorkspaceMembershipFacts? {
            let zoneID = CloudKitProductionBoundary.zoneID(for: context.namespace)
            switch context.databaseScope {
            case .ownerPrivate: return try await ownerMembership(zoneID: zoneID)
            case .participantShared: return try await participantMembership(zoneID: zoneID, shareRecordName: context.shareRecordName)
            }
        }

        private func ownerMembership(zoneID: CKRecordZone.ID) async throws -> CloudKitWorkspaceMembershipFacts? {
            let database = container.privateCloudDatabase
            do {
                _ = try await database.recordZone(for: zoneID)
            } catch {
                if CloudKitWorkspaceErrorMapping.isMissing(error) { return nil }
                throw CloudKitWorkspaceErrorMapping.mapped(error)
            }
            let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
            let share = try await CloudKitWorkspaceErrorMapping.existingRecord(shareID, in: database)
            return CloudKitWorkspaceMembershipFacts(sharePermission: .owner, shareRecordName: share is CKShare ? CKRecordNameZoneWideShare : nil)
        }

        private func participantMembership(zoneID: CKRecordZone.ID, shareRecordName: String?) async throws -> CloudKitWorkspaceMembershipFacts? {
            guard let shareRecordName else { return nil }
            let shareID = CKRecord.ID(recordName: shareRecordName, zoneID: zoneID)
            guard let share = try await CloudKitWorkspaceErrorMapping.existingRecord(shareID, in: container.sharedCloudDatabase) as? CKShare,
                let participant = share.currentUserParticipant, participant.acceptanceStatus == .accepted, participant.role != .owner,
                let permission = participant.permission.workspacePermission
            else { return nil }
            return CloudKitWorkspaceMembershipFacts(sharePermission: permission, shareRecordName: shareRecordName)
        }

        private func shareMetadata(for invitation: CloudKitShareInvitation) async throws -> CKShare.Metadata {
            switch invitation {
            case let .archivedMetadata(data):
                let unarchived: CKShare.Metadata?
                do { unarchived = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKShare.Metadata.self, from: data) } catch {
                    throw CloudKitWorkspaceError.invalidInvitation
                }
                guard let metadata = unarchived else { throw CloudKitWorkspaceError.invalidInvitation }
                return metadata
            case let .shareURL(url):
                return try await CloudKitWorkspaceErrorMapping.perform { try await fetchShareMetadata(url) }
            }
        }

        private func fetchShareMetadata(_ url: URL) async throws -> CKShare.Metadata {
            try await withCheckedThrowingContinuation { continuation in
                let operation = CKFetchShareMetadataOperation(shareURLs: [url])
                let box = CloudKitShareMetadataBox()
                operation.perShareMetadataResultBlock = { _, result in box.store(result) }
                operation.fetchShareMetadataResultBlock = { result in
                    switch result {
                    case .success: continuation.resume(with: box.result())
                    case let .failure(error): continuation.resume(throwing: error)
                    }
                }
                container.add(operation)
            }
        }
    }

    /// Collects the single per-URL metadata result of a fetch operation.
    private final class CloudKitShareMetadataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Result<CKShare.Metadata, Error>?

        func store(_ result: Result<CKShare.Metadata, Error>) {
            lock.lock()
            defer { lock.unlock() }
            if stored == nil { stored = result }
        }

        func result() -> Result<CKShare.Metadata, Error> {
            lock.lock()
            defer { lock.unlock() }
            return stored ?? .failure(CloudKitWorkspaceError.invalidInvitation)
        }
    }

#endif
