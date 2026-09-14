import Foundation
import NetworkModel

struct WorkspaceSentinelPayload: Codable, Hashable, Sendable {
    let workspaceID: ObjectID
    let zoneName: String
    let zoneOwnerRecordName: String
    let lifecycle: WorkspaceLifecycle

    func matches(_ zone: AuthoritativeWorkspaceZone) -> Bool {
        workspaceID == zone.workspaceID && zoneName == zone.zoneName && zoneOwnerRecordName == zone.zoneOwnerRecordName
    }
}

struct TransferSessionAssertionPayload: Codable, Hashable, Sendable {
    let transferID: ObjectID
    let operationID: ObjectID
    let epoch: UInt64
    let expectedMemberCount: Int
    let expectedRollingDigest: String
    let cursor: Int
    let rollingDigest: String
    let status: String

    var isComplete: Bool {
        status == "complete" && cursor >= 0 && expectedMemberCount >= 0 && cursor == expectedMemberCount && rollingDigest == expectedRollingDigest
            && !rollingDigest.isEmpty
    }
}

public enum AuthoritativeActivationMutationRepositoryError: Error, Hashable, Sendable {
    case unsupported
}
