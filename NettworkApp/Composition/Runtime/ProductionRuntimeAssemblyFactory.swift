import CloudKit
import CloudSync
import ContentSafety
import Foundation
import ImportExport
import NetworkModel
import Persistence
import SwiftData
import WorkspaceChangeControl
import WorkspaceServices

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
            let authorities = makeRuntimeOrganizationAuthorities(input, foundation: foundation, cloud: cloud, transfer: transfer)
            let floorPlan = makeRuntimeFloorPlanGraph(input, foundation: foundation, cloud: cloud, attachment: attachment, authorities: authorities)
            let featureInput = makeRuntimeFeatureInput(
                input,
                platformCapabilities: resolvedPlatformCapabilities(
                    organizationOverride: input.platformCapabilities,
                    system: systemPlatformCapabilities
                ),
                foundation: foundation, attachment: attachment, transfer: transfer,
                authorities: authorities, floorPlan: floorPlan)
            return makeRuntimeAssembly(
                foundation: foundation, cloud: cloud, attachment: attachment, transfer: transfer,
                authorities: authorities, floorPlan: floorPlan, featureInput: featureInput)
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

    static func makeRuntimeAssembly(
        foundation: ProductionRuntimeFoundation,
        cloud: ProductionRuntimeCloudGraph,
        attachment: ProductionRuntimeAttachmentGraph,
        transfer: ProductionRuntimeTransferGraph,
        authorities: ProductionOrganizationAuthorities,
        floorPlan: ProductionRuntimeFloorPlanGraph,
        featureInput: ProductionFeatureGraphInput
    ) -> ProductionRuntimeAssembly {
        let composition = AppRuntimeComposition.production(
            features: ProductionFeatureGraphFactory.make(featureInput), activateWorkspace: foundation.activateWorkspace,
            syncCoordinator: authorities.synchronizer, invalidateWorkspace: foundation.invalidateWorkspace)
        return ProductionRuntimeAssembly(
            composition: composition,
            activateWorkspace: foundation.activateWorkspace,
            invalidateWorkspace: foundation.invalidateWorkspace,
            foundation: foundation,
            cloud: cloud,
            attachment: attachment,
            transfer: transfer,
            authorities: authorities,
            floorPlan: floorPlan
        )
    }
}
