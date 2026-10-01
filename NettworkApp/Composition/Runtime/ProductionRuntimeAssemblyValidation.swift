import Foundation
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
        ].map(\.standardizedFileURL)
        guard directories.allSatisfy(\.isFileURL),
            Set(directories).count == directories.count
        else {
            throw ProductionRuntimeAssemblyError.invalidConfiguration("private directories")
        }
    }
}
