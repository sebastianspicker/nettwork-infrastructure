import Foundation
import NetworkModel
import WorkspaceChangeControl

/// A presentation of the current, independently verified workspace membership.
/// This is deliberately scoped to the current participant: CloudKit share
/// participant enumeration remains inside the injected workspace authority.
public struct WorkspaceParticipantStatusPresentation: Equatable, Sendable {
    public let workspaceName: String
    public let participantRecordName: String
    public let role: OfficialClientRole?
    public let permission: WorkspaceSharePermission
    public let shareRecordName: String?
    public let membershipIsVerified: Bool
    public let disclosure: String

    public init(
        workspaceName: String,
        participantRecordName: String,
        role: OfficialClientRole?,
        permission: WorkspaceSharePermission,
        shareRecordName: String?,
        membershipIsVerified: Bool,
        disclosure: String
    ) {
        self.workspaceName = workspaceName
        self.participantRecordName = participantRecordName
        self.role = role
        self.permission = permission
        self.shareRecordName = shareRecordName
        self.membershipIsVerified = membershipIsVerified
        self.disclosure = disclosure
    }
}

public struct WorkspaceInviteRequest: Equatable, Sendable {
    public let participantCloudKitUserRecordName: String
    public let permission: WorkspaceSharePermission

    public init(participantCloudKitUserRecordName: String, permission: WorkspaceSharePermission) {
        self.participantCloudKitUserRecordName = participantCloudKitUserRecordName
        self.permission = permission
    }
}

/// The opaque metadata is only returned to the app integration layer for
/// delivery to the invited participant. The administration screen never
/// renders or persists it.
public struct WorkspaceInviteReceipt: Equatable, Sendable {
    public let participantCloudKitUserRecordName: String
    public let shareMetadata: Data

    public init(participantCloudKitUserRecordName: String, shareMetadata: Data) {
        self.participantCloudKitUserRecordName = participantCloudKitUserRecordName
        self.shareMetadata = shareMetadata
    }
}

@MainActor
public protocol WorkspaceAdministrationService {
    func participantStatus() async throws -> WorkspaceParticipantStatusPresentation
    func inviteParticipant(_ request: WorkspaceInviteRequest) async throws -> WorkspaceInviteReceipt
    func acceptShare(metadata: Data) async throws -> WorkspaceAcceptedShare
    func revokeCurrentShare() async throws
}

public struct WorkspaceAcceptedShare: Sendable {
    public let account: AccountContext
    public let presentation: WorkspaceParticipantStatusPresentation

    public init(account: AccountContext, presentation: WorkspaceParticipantStatusPresentation) {
        self.account = account
        self.presentation = presentation
    }
}
