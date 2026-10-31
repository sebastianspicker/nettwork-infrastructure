import Foundation
import NetworkModel
import WorkspaceChangeControl

/// The bootstrap sentinel `CloudWorkspaceRecord(lifecycle: .empty(epoch: 0))`
/// at `AuthoritativeActivationMutation.bootstrapSentinelResourceKey`, with the
/// scalar fields `CloudKitRecordTransport` writes for a live business save.
struct CloudKitWorkspaceSentinel: Hashable, Sendable {
    let recordName: String
    let recordType: String
    let resourceKey: String
    let workspaceID: String
    let schemaVersion: Int
    let payload: Data
    let visibility: Data

    init(zone: AuthoritativeWorkspaceZone) throws {
        let key = AuthoritativeActivationMutation.bootstrapSentinelResourceKey(for: zone.workspaceID)
        let record = CloudWorkspaceRecord(
            workspaceID: zone.workspaceID, zoneName: zone.zoneName, zoneOwnerRecordName: zone.zoneOwnerRecordName, lifecycle: .empty(epoch: 0))
        self.recordName = CloudRecordNaming.recordName(for: key, workspaceID: zone.workspaceID)
        self.recordType = CloudRecordNaming.workspaceRecordType
        self.resourceKey = key.description
        self.workspaceID = zone.workspaceID.description
        self.schemaVersion = CloudRecordNaming.schemaVersion
        self.payload = try CloudDeterministicCoding.encode(record)
        self.visibility = try CloudDeterministicCoding.encode(WorkspaceRecordVisibility.live)
    }

    /// An existing sentinel may have moved past `.empty` through later
    /// activations; it is admitted when its identity and zone binding match.
    /// It is never overwritten.
    func admits(_ existing: CloudKitWorkspaceSentinelSnapshot, zone: AuthoritativeWorkspaceZone) -> Bool {
        guard existing.recordType == recordType, existing.resourceKey == resourceKey, existing.workspaceID == workspaceID, !existing.isDeleted,
            let payload = existing.payload
        else { return false }
        let record: CloudWorkspaceRecord
        do { record = try CloudDeterministicCoding.decode(CloudWorkspaceRecord.self, from: payload) } catch { return false }
        return record.workspaceID == zone.workspaceID && record.zoneName == zone.zoneName && record.zoneOwnerRecordName == zone.zoneOwnerRecordName
    }
}

/// CloudKit-independent view of a fetched sentinel record.
struct CloudKitWorkspaceSentinelSnapshot: Hashable, Sendable {
    let recordType: String
    let resourceKey: String?
    let workspaceID: String?
    let isDeleted: Bool
    let payload: Data?
}

enum CloudKitCreateOutcome: Hashable, Sendable {
    case created
    /// The conditional create lost to an existing record.
    case alreadyExists
}

/// Seam over the owner's private database for the bootstrap steps. Creates are
/// conditional: an existing record yields `.alreadyExists`, never an overwrite.
protocol CloudKitWorkspaceBootstrapDatabase: Sendable {
    func zoneExists(_ zone: AuthoritativeWorkspaceZone) async throws -> Bool
    func createZone(_ zone: AuthoritativeWorkspaceZone) async throws
    func sentinel(named recordName: String, in zone: AuthoritativeWorkspaceZone) async throws -> CloudKitWorkspaceSentinelSnapshot?
    func createSentinel(_ sentinel: CloudKitWorkspaceSentinel, in zone: AuthoritativeWorkspaceZone) async throws -> CloudKitCreateOutcome
    func zoneShareExists(in zone: AuthoritativeWorkspaceZone) async throws -> Bool
    func createZoneShare(in zone: AuthoritativeWorkspaceZone) async throws -> CloudKitCreateOutcome
}

/// Idempotent bootstrap: zone, then sentinel, then zone-wide share. Re-running
/// after a partial failure finds what exists and creates only what is missing.
enum CloudKitWorkspaceBootstrap {
    static func run(zone: AuthoritativeWorkspaceZone, database: any CloudKitWorkspaceBootstrapDatabase) async throws {
        if try await !database.zoneExists(zone) { try await database.createZone(zone) }
        try await ensureSentinel(CloudKitWorkspaceSentinel(zone: zone), zone: zone, database: database)
        if try await !database.zoneShareExists(in: zone) { _ = try await database.createZoneShare(in: zone) }
    }

    private static func ensureSentinel(
        _ sentinel: CloudKitWorkspaceSentinel, zone: AuthoritativeWorkspaceZone, database: any CloudKitWorkspaceBootstrapDatabase
    ) async throws {
        if let existing = try await database.sentinel(named: sentinel.recordName, in: zone) {
            guard sentinel.admits(existing, zone: zone) else { throw CloudKitWorkspaceError.sentinelMismatch }
            return
        }
        guard try await database.createSentinel(sentinel, in: zone) == .alreadyExists else { return }
        guard let existing = try await database.sentinel(named: sentinel.recordName, in: zone), sentinel.admits(existing, zone: zone) else {
            throw CloudKitWorkspaceError.sentinelMismatch
        }
    }
}
