import CloudKit
import CloudSync
import ContentSafety
import Foundation
import ImportExport
import NetworkModel
import Persistence
import SwiftData
import WorkspaceChangeControl

extension ProductionRuntimeAssembly {
    static func make(
        organization input: OrganizationInput,
        systemPlatformCapabilities: OrganizationInput.PlatformCapabilities
    ) async throws -> ProductionRuntimeAssembly {
        try validate(input)
        let foundation = try await makeRuntimeFoundation(input)
        do {
            let cloud = try await makeRuntimeCloudGraph(input, foundation: foundation)
            let attachment = try makeRuntimeAttachmentGraph(input, foundation: foundation, cloud: cloud)
            let transfer = makeRuntimeTransferGraph(input, foundation: foundation, cloud: cloud)
            let organization = makeRuntimeOrganizationGraph(input, foundation: foundation, cloud: cloud, transfer: transfer)
            let floorPlan = makeRuntimeFloorPlanGraph(input, foundation: foundation, cloud: cloud, attachment: attachment, organization: organization)
            let featureInput = makeRuntimeFeatureInput(
                input,
                platformCapabilities: resolvedPlatformCapabilities(
                    organizationOverride: input.platformCapabilities,
                    system: systemPlatformCapabilities
                ),
                foundation: foundation, attachment: attachment, transfer: transfer,
                organization: organization, floorPlan: floorPlan)
            return makeRuntimeAssembly(
                foundation: foundation, cloud: cloud, attachment: attachment, transfer: transfer,
                organization: organization, floorPlan: floorPlan, featureInput: featureInput)
        } catch {
            await foundation.lifecycle.invalidateCurrentSession()
            throw error
        }
    }

    static func resolvedPlatformCapabilities(
        organizationOverride: OrganizationInput.PlatformCapabilities?,
        system: OrganizationInput.PlatformCapabilities
    ) -> OrganizationInput.PlatformCapabilities {
        organizationOverride ?? system
    }

    private static func validate(_ input: OrganizationInput) throws {
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
