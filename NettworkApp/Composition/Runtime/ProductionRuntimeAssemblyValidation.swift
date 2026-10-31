import CloudSync
import Foundation
import WorkspaceChangeControl
import WorkspaceServices

extension ProductionRuntimeAssembly {
    static func validate(_ input: OrganizationInput) throws {
        let requiredStrings = [
            "workspaceName": input.cloudWorkspace.workspaceName,
            "containerIdentifier": input.cloudWorkspace.account.namespace.containerIdentifier,
            "accountRecordName": input.cloudWorkspace.account.namespace.cloudKitAccountRecordName,
            "zoneName": input.cloudWorkspace.account.namespace.zoneName,
            "zoneOwnerRecordName": input.cloudWorkspace.account.namespace.zoneOwnerRecordName,
            "telemetrySubsystem": input.cloudWorkspace.telemetrySubsystem,
        ]
        for (field, value) in requiredStrings where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ProductionRuntimeAssemblyError.invalidConfiguration(field)
        }
        guard input.workspaceStorage.attachmentStagingLifetime > 0 else {
            throw ProductionRuntimeAssemblyError.invalidConfiguration("attachmentStagingLifetime")
        }
        try validateBackendWiring(
            backend: input.cloudWorkspace.backend.kind,
            account: input.cloudWorkspace.account,
            stagedTransferGCPolicy: input.cloudWorkspace.stagedTransferGCPolicy
        )
        try ProductionOperationBoundary.validate(
            policies: input.operationGovernance.operationPolicies,
            budgets: input.operationGovernance.operationPerformanceBudgets
        )
        let directories = [
            input.workspaceStorage.attachmentDirectory,
            input.workspaceStorage.attachmentStagingDirectory,
            input.workspaceStorage.csvStagingDirectory,
            input.workspaceStorage.archiveRestoreStagingDirectory,
            input.workspaceStorage.auditPrivateDirectory,
            input.workspaceStorage.historyDirectory,
        ].map(\.standardizedFileURL)
        guard directories.allSatisfy(\.isFileURL),
            Set(directories).count == directories.count
        else {
            throw ProductionRuntimeAssemblyError.invalidConfiguration("private directories")
        }
    }

    /// Reserved container-identifier prefix of local (non-CloudKit) namespaces.
    nonisolated static let localContainerPrefix = "local."

    /// Rejects cross-wired backends: a local namespace may only drive the local
    /// backend, and the local backend only accepts an owner-private owner
    /// namespace without staged-transfer GC.
    nonisolated static func validateBackendWiring(
        backend: OrganizationInput.CloudWorkspace.BackendKind,
        account: AccountContext,
        stagedTransferGCPolicy: CloudStagedTransferGCPolicy?
    ) throws {
        let isLocalNamespace = account.namespace.containerIdentifier.hasPrefix(localContainerPrefix)
        switch backend {
        case .cloudKit:
            guard !isLocalNamespace else { throw ProductionRuntimeAssemblyError.localNamespaceOnCloudKitBackend }
        case .local:
            guard isLocalNamespace else { throw ProductionRuntimeAssemblyError.localBackendRequiresLocalNamespace }
            guard account.databaseScope == .ownerPrivate, account.sharePermission == .owner else {
                throw ProductionRuntimeAssemblyError.localBackendRequiresOwnerPrivateScope
            }
            guard stagedTransferGCPolicy == nil else { throw ProductionRuntimeAssemblyError.localBackendRejectsStagedTransferGC }
        }
    }
}
