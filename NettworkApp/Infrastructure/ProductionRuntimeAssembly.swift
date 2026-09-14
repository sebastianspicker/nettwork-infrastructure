import CloudKit
import CloudSync
import ContentSafety
import Foundation
import ImportExport
import NetworkModel
import Persistence
import SwiftData
import WorkspaceChangeControl

/// The transfer actor remains behind this narrow retained seam because it owns
/// staged payload activation. Production assembly constructs the concrete
/// authority itself; organization input cannot substitute a permissive writer.
protocol ProductionWorkspaceTransferAuthorityProviding: AnyObject,
    CSVImportActivationAuthority,
    ArchiveExportSource,
    ArchiveRestoreActivationAuthority,
    TransferCurrentAccountProviding
{}

extension ProductionWorkspaceTransferAuthority: ProductionWorkspaceTransferAuthorityProviding {}

enum ProductionRuntimeAssemblyError: LocalizedError {
    case verifiedAccountMismatch
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .verifiedAccountMismatch:
            "The verified CloudKit account no longer matches the assembled workspace."
        case .invalidConfiguration(let field):
            "The production runtime configuration is invalid: \(field)."
        }
    }
}

/// Owns the live production object graph. It has no convenience defaults: the
/// organization supplies account authority, policy, directory, and platform
/// presentation seams before the app can leave its fail-closed default graph.
@MainActor
final class ProductionRuntimeAssembly {
    let composition: AppRuntimeComposition
    let activateWorkspace: () async throws -> Void
    let invalidateWorkspace: () async -> Void

    // Retain the authoritative graph for the lifetime of the presentation
    // composition. Several members are protocol-typed in feature models.
    private let foundation: ProductionRuntimeFoundation
    private let cloud: ProductionRuntimeCloudGraph
    private let attachment: ProductionRuntimeAttachmentGraph
    private let transfer: ProductionRuntimeTransferGraph
    private let organization: ProductionRuntimeOrganizationGraph
    private let floorPlan: ProductionRuntimeFloorPlanGraph

    init(
        composition: AppRuntimeComposition,
        activateWorkspace: @escaping () async throws -> Void,
        invalidateWorkspace: @escaping () async -> Void,
        foundation: ProductionRuntimeFoundation,
        cloud: ProductionRuntimeCloudGraph,
        attachment: ProductionRuntimeAttachmentGraph,
        transfer: ProductionRuntimeTransferGraph,
        organization: ProductionRuntimeOrganizationGraph,
        floorPlan: ProductionRuntimeFloorPlanGraph
    ) {
        self.composition = composition
        self.activateWorkspace = activateWorkspace
        self.invalidateWorkspace = invalidateWorkspace
        self.foundation = foundation
        self.cloud = cloud
        self.attachment = attachment
        self.transfer = transfer
        self.organization = organization
        self.floorPlan = floorPlan
    }
}
