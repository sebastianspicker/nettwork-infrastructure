import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Typed, definitive failures of the CloudKit workspace context store, share
/// service and bootstrapper. Reachability loss is reported separately as
/// `CloudVerificationUnavailableError`.
public enum CloudKitWorkspaceError: Error, Hashable, Sendable {
    /// The request names another CloudKit container than the configured one.
    case containerMismatch
    /// The context violates the owner or participant invariants of its scope.
    case invalidContext
    /// The context was never verified by this store.
    case unknownContext
    case contextStoreCorrupt
    case contextStoreReadFailed(String)
    case contextStoreWriteFailed(String)
    /// The invitation bytes are neither a share URL nor archived share metadata.
    case invalidInvitation
    /// The share is not a zone-wide workspace share this account may join.
    case invitationRejected
    case invalidParticipant
    case shareRecordMismatch
    case concurrentChange
    case shareURLUnavailable
    /// An existing workspace sentinel does not belong to this workspace zone.
    case sentinelMismatch
    case accountUnavailable
    case permissionDenied
    case quotaExceeded
    case requestFailed(code: Int)
}

/// CloudKit-independent facts read for an existing membership. `nil` from a
/// reader means the zone or share is definitively gone.
struct CloudKitWorkspaceMembershipFacts: Hashable, Sendable {
    let sharePermission: WorkspaceSharePermission
    let shareRecordName: String?
}

/// CloudKit-independent facts of a share after `accept`, copied from the share
/// metadata and the current user's participant entry.
struct CloudKitAcceptedShareFacts: Hashable, Sendable {
    let containerIdentifier: String
    let zoneName: String
    let zoneOwnerRecordName: String
    let shareRecordName: String
    let isZoneWide: Bool
    let isAccepted: Bool
    let isOwnerRole: Bool
    /// `nil` when CloudKit reports no or an unknown participant permission.
    let permission: WorkspaceSharePermission?
}

/// Seam over every CloudKit read the context store performs, so the store's
/// persistence and comparison rules are testable without a container.
protocol CloudKitWorkspaceMembershipReading: Sendable {
    func acceptShare(invitation: Data) async throws -> CloudKitAcceptedShareFacts
    func membership(of context: AccountContext) async throws -> CloudKitWorkspaceMembershipFacts?
}

/// Seam over the owner's zone-wide share for the share service.
protocol CloudKitWorkspaceShareWriting: Sendable {
    /// Adds the participant, or updates its permission, on the zone-wide share
    /// (creating the share when it is missing) and returns the share URL.
    func addParticipant(recordName: String, permission: WorkspaceSharePermission, in zone: AuthoritativeWorkspaceZone) async throws -> URL
    /// Deletes the zone-wide share; a share that is already gone is success.
    func deleteZoneShare(in zone: AuthoritativeWorkspaceZone) async throws
}

/// Pure admission rules shared by the context store. Every rule fails closed.
enum CloudKitWorkspaceContextRules {
    static let zoneNamePrefix = "nettwork.workspace."
    /// CloudKit's placeholder owner name; a persisted namespace always names the real owner.
    static let defaultOwnerName = "__defaultOwner__"

    static func ownerNamespace(workspaceID: ObjectID, containerIdentifier: String, accountRecordName: String) -> PersistenceNamespace {
        PersistenceNamespace(
            containerIdentifier: containerIdentifier, cloudKitAccountRecordName: accountRecordName, workspaceID: workspaceID,
            zoneName: CloudRecordNaming.zoneName(for: workspaceID), zoneOwnerRecordName: accountRecordName, sessionGeneration: 0)
    }

    /// Parses only names produced by `CloudRecordNaming.zoneName(for:)`.
    static func workspaceID(fromZoneName zoneName: String) -> ObjectID? {
        guard zoneName.hasPrefix(zoneNamePrefix), let uuid = UUID(uuidString: String(zoneName.dropFirst(zoneNamePrefix.count))) else { return nil }
        let workspaceID = ObjectID(uuid)
        return CloudRecordNaming.zoneName(for: workspaceID) == zoneName ? workspaceID : nil
    }

    static func isValidRecordName(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) && value != defaultOwnerName
    }

    static func isParticipantPermission(_ permission: WorkspaceSharePermission?) -> Bool {
        permission == .readOnly || permission == .readWrite
    }

    /// Validates an owner context: private scope, owner permission, the configured
    /// container, the account as zone owner, and the canonical zone name.
    static func validateOwner(_ context: AccountContext, containerIdentifier: String?) throws {
        let namespace = context.namespace
        guard let containerIdentifier, !containerIdentifier.isEmpty, namespace.containerIdentifier == containerIdentifier else {
            throw CloudKitWorkspaceError.containerMismatch
        }
        guard context.databaseScope == .ownerPrivate, context.sharePermission == .owner,
            isValidRecordName(namespace.cloudKitAccountRecordName), namespace.zoneOwnerRecordName == namespace.cloudKitAccountRecordName,
            namespace.zoneName == CloudRecordNaming.zoneName(for: namespace.workspaceID)
        else { throw CloudKitWorkspaceError.invalidContext }
    }

    /// Builds the participant context for an accepted share, or throws.
    static func participantContext(
        from facts: CloudKitAcceptedShareFacts, accountRecordName: String, containerIdentifier: String, verifiedAt: Date
    ) throws -> AccountContext {
        guard !containerIdentifier.isEmpty, facts.containerIdentifier == containerIdentifier else { throw CloudKitWorkspaceError.containerMismatch }
        guard isValidRecordName(accountRecordName) else { throw CloudKitWorkspaceError.invalidContext }
        guard facts.isZoneWide, facts.isAccepted, !facts.isOwnerRole, let permission = facts.permission, isParticipantPermission(permission),
            isValidRecordName(facts.zoneOwnerRecordName), facts.zoneOwnerRecordName != accountRecordName, isValidRecordName(facts.shareRecordName),
            let workspaceID = workspaceID(fromZoneName: facts.zoneName)
        else { throw CloudKitWorkspaceError.invitationRejected }
        let namespace = PersistenceNamespace(
            containerIdentifier: containerIdentifier, cloudKitAccountRecordName: accountRecordName, workspaceID: workspaceID, zoneName: facts.zoneName,
            zoneOwnerRecordName: facts.zoneOwnerRecordName, sessionGeneration: 0)
        return AccountContext(
            namespace: namespace, databaseScope: .participantShared, sharePermission: permission, shareRecordName: facts.shareRecordName,
            verifiedAt: verifiedAt)
    }

    /// Returns `context` unchanged (same `verifiedAt`) when CloudKit still reports
    /// its permission and share; a new context stamped `now` when either changed;
    /// `nil` when the facts are not a valid membership for the context's scope.
    static func refreshed(_ context: AccountContext, facts: CloudKitWorkspaceMembershipFacts, now: Date) -> AccountContext? {
        switch context.databaseScope {
        case .ownerPrivate:
            guard facts.sharePermission == .owner else { return nil }
        case .participantShared:
            guard isParticipantPermission(facts.sharePermission), let share = facts.shareRecordName, share == context.shareRecordName else {
                return nil
            }
        }
        guard facts.sharePermission != context.sharePermission || facts.shareRecordName != context.shareRecordName else { return context }
        return AccountContext(
            namespace: context.namespace, databaseScope: context.databaseScope, sharePermission: facts.sharePermission,
            shareRecordName: facts.shareRecordName, verifiedAt: now)
    }
}

/// The bytes exchanged between `invite` and `acceptShare`: either the UTF-8
/// share URL returned to the owner, or `CKShare.Metadata` archived with secure
/// coding by the platform share-acceptance handoff.
enum CloudKitShareInvitation: Hashable, Sendable {
    case shareURL(URL)
    case archivedMetadata(Data)

    static let maximumByteCount = 256 * 1_024

    static func encode(shareURL: URL) throws -> Data {
        guard shareURL.scheme == "https", shareURL.host?.isEmpty == false else { throw CloudKitWorkspaceError.shareURLUnavailable }
        return Data(shareURL.absoluteString.utf8)
    }

    static func decode(_ data: Data) throws -> CloudKitShareInvitation {
        guard !data.isEmpty, data.count <= maximumByteCount else { throw CloudKitWorkspaceError.invalidInvitation }
        guard let text = String(data: data, encoding: .utf8), text.hasPrefix("https://") else { return .archivedMetadata(data) }
        guard let url = URL(string: text), url.scheme == "https", url.host?.isEmpty == false, url.absoluteString == text else {
            throw CloudKitWorkspaceError.invalidInvitation
        }
        return .shareURL(url)
    }
}
