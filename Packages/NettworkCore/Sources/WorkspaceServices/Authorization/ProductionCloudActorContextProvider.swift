import CloudSync
import Foundation
import WorkspaceChangeControl

/// Typed failures of the CloudKit actor and installation providers.
public enum ProductionCloudIdentityError: Error, Equatable, Sendable {
    /// The organization policy does not know the account.
    case unknownAccount
    /// The database scope and share permission of the account disagree.
    case inconsistentAccountScope
    /// The policy granted a role above what the share permission allows.
    case roleExceedsSharePermission
    case invalidInstallationID
    /// The actor was resolved for another installation.
    case installationMismatch
    case installationCorrupt
    case installationReadFailed(String)
    case installationWriteFailed(String)
}

extension ProductionCloudIdentityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unknownAccount: "This iCloud account is not a member of the organization. Ask your administrator for access."
        case .inconsistentAccountScope, .roleExceedsSharePermission: "Your workspace access could not be verified. Open the workspace again."
        case .invalidInstallationID, .installationMismatch: "This device's installation identity does not match the session. Restart the app."
        case .installationCorrupt: "This device's installation identity is damaged and was left untouched. Contact your administrator."
        case .installationReadFailed(let reason): "This device's installation identity could not be read: \(reason)"
        case .installationWriteFailed(let reason): "This device's installation identity could not be saved: \(reason)"
        }
    }
}

/// Organization role policy for CloudKit actors, keyed by account record name
/// and share permission. A `nil` role means the account is unknown.
public struct ProductionCloudActorRolePolicy: Sendable {
    private let resolve: @Sendable (_ accountRecordName: String, _ permission: WorkspaceSharePermission) -> OfficialClientRole?

    public init(resolve: @escaping @Sendable (_ accountRecordName: String, _ permission: WorkspaceSharePermission) -> OfficialClientRole?) {
        self.resolve = resolve
    }

    /// Every listed account receives the highest role its share permission
    /// allows (`ceiling(for:)`); unlisted accounts are unknown.
    public static func sharePermissionRoles(accounts: Set<String>) -> Self {
        Self { accountRecordName, permission in accounts.contains(accountRecordName) ? ceiling(for: permission) : nil }
    }

    /// Owner → administrator, read-write participant → technician, read-only participant → viewer.
    public static func ceiling(for permission: WorkspaceSharePermission) -> OfficialClientRole {
        switch permission {
        case .owner: .administrator
        case .readWrite: .technician
        case .readOnly: .viewer
        }
    }

    func role(accountRecordName: String, permission: WorkspaceSharePermission) -> OfficialClientRole? {
        resolve(accountRecordName, permission)
    }
}

/// Resolves the CloudKit actor from the verified account context and the
/// organization policy. The role can never exceed the share permission's
/// ceiling, and unknown accounts or inconsistent scopes throw.
public struct ProductionCloudActorContextProvider: CloudForegroundActorContextProvider {
    private let policy: ProductionCloudActorRolePolicy
    private let installationID: String

    public init(policy: ProductionCloudActorRolePolicy, installationID: String) {
        self.policy = policy
        self.installationID = installationID
    }

    public func actorContext(for account: AccountContext) async throws -> ActorContext {
        guard !installationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProductionCloudIdentityError.invalidInstallationID }
        let accountRecordName = account.namespace.cloudKitAccountRecordName
        let isOwner = account.databaseScope == .ownerPrivate
        guard !accountRecordName.isEmpty, isOwner == (account.sharePermission == .owner) else {
            throw ProductionCloudIdentityError.inconsistentAccountScope
        }
        guard let role = policy.role(accountRecordName: accountRecordName, permission: account.sharePermission) else {
            throw ProductionCloudIdentityError.unknownAccount
        }
        guard Self.rank(role) <= Self.rank(ProductionCloudActorRolePolicy.ceiling(for: account.sharePermission)) else {
            throw ProductionCloudIdentityError.roleExceedsSharePermission
        }
        return ActorContext(
            cloudKitUserRecordName: accountRecordName, role: role, installationID: installationID, sessionGeneration: account.namespace.sessionGeneration)
    }

    private static func rank(_ role: OfficialClientRole) -> Int {
        switch role {
        case .viewer: 0
        case .technician: 1
        case .administrator: 2
        }
    }
}
