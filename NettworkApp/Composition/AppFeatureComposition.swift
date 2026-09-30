import ContentSafety
import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import SwiftUI
import WorkspaceChangeControl

/// Complete model graph supplied after a verified account/workspace has been
/// activated. Every state-changing screen still delegates through its own
/// authorized service; this registry only owns navigation composition.
@MainActor
struct AppFeatureComposition {
    let inventory: InventoryExploreModel
    let topology: TopologyWorkspaceModel
    let trace: TraceInspectionModel
    let scan: ScanIntakeModel
    let workOrders: OperationsFeatureViewModel
    let floorPlans: FloorPlanViewModel
    let ipam: IPAMWorkspaceModel
    let templates: TemplateCatalogModel
    let operations: OperationsReadViewModel
    let administration: WorkspaceAdministrationViewModel
    let reconciliation: ReconciliationViewModel
    let transfer: TransferFeatureViewModel
    let labels: LabelSheetModel

    let operationsAuthorization: OperationsAuthorization
    let cancellationReleaseAuthorization: (CancellationReleaseRequest) -> CancellationReleaseAuthorization?
    let workOrderEvidenceSource: () -> (any OpaqueContentSource)?
    let workOrderEvidenceAuthorization: () -> AuthorizedOperationContext?
    private let optionalCapabilities: AppFeatureOptionalCapabilities

    var auditExportAuthorization: (() -> AuthorizedOperationContext?)? { optionalCapabilities.auditExportAuthorization }
    var floorPlanImportSource: (() -> (any OpaqueContentSource)?)? { optionalCapabilities.floorPlanImportSource }
    var attachmentAuthorization: (() -> AuthorizedOperationContext?)? { optionalCapabilities.attachmentAuthorization }
    var floorPlanPreviewAuthorization: (() -> AuthorizedOperationContext?)? { optionalCapabilities.floorPlanPreviewAuthorization }
    var csvImportDocument: (() -> CSVImportDocument?)? { optionalCapabilities.csvImportDocument }
    var importAuthorization: (() -> AuthorizedOperationContext?)? { optionalCapabilities.importAuthorization }
    var csvExportAuthorization: (() -> AuthorizedOperationContext?)? { optionalCapabilities.csvExportAuthorization }
    var csvExportDestination: (any CSVWorkspaceExportDestination)? { optionalCapabilities.csvExportDestination }
    var archiveExportAuthorization: (() -> AuthorizedOperationContext?)? { optionalCapabilities.archiveExportAuthorization }
    var archiveRestoreSource: (() -> (any ArchiveEntrySource)?)? { optionalCapabilities.archiveRestoreSource }
    var archivePackageSource: ((URL) throws -> any ArchiveEntrySource)? { optionalCapabilities.archivePackageSource }
    var archiveRestoreAuthorization: (() -> AuthorizedOperationContext?)? { optionalCapabilities.archiveRestoreAuthorization }
    var workspaceShareMetadata: (() -> Data?)? { optionalCapabilities.workspaceShareMetadata }
    var onWorkspaceInvitationPrepared: ((WorkspaceInviteReceipt) -> Void)? { optionalCapabilities.onWorkspaceInvitationPrepared }

    init(
        inventory: InventoryExploreModel,
        topology: TopologyWorkspaceModel,
        trace: TraceInspectionModel,
        scan: ScanIntakeModel,
        workOrders: OperationsFeatureViewModel,
        floorPlans: FloorPlanViewModel,
        ipam: IPAMWorkspaceModel,
        templates: TemplateCatalogModel,
        operations: OperationsReadViewModel,
        administration: WorkspaceAdministrationViewModel,
        reconciliation: ReconciliationViewModel,
        transfer: TransferFeatureViewModel,
        labels: LabelSheetModel,
        operationsAuthorization: OperationsAuthorization,
        cancellationReleaseAuthorization: @escaping (CancellationReleaseRequest) -> CancellationReleaseAuthorization?,
        workOrderEvidenceSource: @escaping () -> (any OpaqueContentSource)?,
        workOrderEvidenceAuthorization: @escaping () -> AuthorizedOperationContext?,
        optionalCapabilities: AppFeatureOptionalCapabilities
    ) {
        self.inventory = inventory
        self.topology = topology
        self.trace = trace
        self.scan = scan
        self.workOrders = workOrders
        self.floorPlans = floorPlans
        self.ipam = ipam
        self.templates = templates
        self.operations = operations
        self.administration = administration
        self.reconciliation = reconciliation
        self.transfer = transfer
        self.labels = labels
        self.operationsAuthorization = operationsAuthorization
        self.cancellationReleaseAuthorization = cancellationReleaseAuthorization
        self.workOrderEvidenceSource = workOrderEvidenceSource
        self.workOrderEvidenceAuthorization = workOrderEvidenceAuthorization
        self.optionalCapabilities = optionalCapabilities
    }
}

@MainActor
protocol AppFeatureOptionalCapabilitiesProviding {
    var auditExportAuthorization: (() -> AuthorizedOperationContext?)? { get }
    var floorPlanImportSource: (() -> (any OpaqueContentSource)?)? { get }
    var attachmentAuthorization: (() -> AuthorizedOperationContext?)? { get }
    var floorPlanPreviewAuthorization: (() -> AuthorizedOperationContext?)? { get }
    var csvImportDocument: (() -> CSVImportDocument?)? { get }
    var importAuthorization: (() -> AuthorizedOperationContext?)? { get }
    var csvExportAuthorization: (() -> AuthorizedOperationContext?)? { get }
    var csvExportDestination: (any CSVWorkspaceExportDestination)? { get }
    var archiveExportAuthorization: (() -> AuthorizedOperationContext?)? { get }
    var archiveRestoreSource: (() -> (any ArchiveEntrySource)?)? { get }
    var archivePackageSource: ((URL) throws -> any ArchiveEntrySource)? { get }
    var archiveRestoreAuthorization: (() -> AuthorizedOperationContext?)? { get }
    var workspaceShareMetadata: (() -> Data?)? { get }
    var onWorkspaceInvitationPrepared: ((WorkspaceInviteReceipt) -> Void)? { get }
}

@MainActor
struct AppFeatureOptionalCapabilities {
    let auditExportAuthorization: (() -> AuthorizedOperationContext?)?
    let floorPlanImportSource: (() -> (any OpaqueContentSource)?)?
    let attachmentAuthorization: (() -> AuthorizedOperationContext?)?
    let floorPlanPreviewAuthorization: (() -> AuthorizedOperationContext?)?
    let csvImportDocument: (() -> CSVImportDocument?)?
    let importAuthorization: (() -> AuthorizedOperationContext?)?
    let csvExportAuthorization: (() -> AuthorizedOperationContext?)?
    let csvExportDestination: (any CSVWorkspaceExportDestination)?
    let archiveExportAuthorization: (() -> AuthorizedOperationContext?)?
    let archiveRestoreSource: (() -> (any ArchiveEntrySource)?)?
    let archivePackageSource: ((URL) throws -> any ArchiveEntrySource)?
    let archiveRestoreAuthorization: (() -> AuthorizedOperationContext?)?
    let workspaceShareMetadata: (() -> Data?)?
    let onWorkspaceInvitationPrepared: ((WorkspaceInviteReceipt) -> Void)?

    init(source: any AppFeatureOptionalCapabilitiesProviding) {
        auditExportAuthorization = source.auditExportAuthorization
        floorPlanImportSource = source.floorPlanImportSource
        attachmentAuthorization = source.attachmentAuthorization
        floorPlanPreviewAuthorization = source.floorPlanPreviewAuthorization
        csvImportDocument = source.csvImportDocument
        importAuthorization = source.importAuthorization
        csvExportAuthorization = source.csvExportAuthorization
        csvExportDestination = source.csvExportDestination
        archiveExportAuthorization = source.archiveExportAuthorization
        archiveRestoreSource = source.archiveRestoreSource
        archivePackageSource = source.archivePackageSource
        archiveRestoreAuthorization = source.archiveRestoreAuthorization
        workspaceShareMetadata = source.workspaceShareMetadata
        onWorkspaceInvitationPrepared = source.onWorkspaceInvitationPrepared
    }
}

@MainActor
final class AppFeatureRegistry {
    typealias SectionBuilder = (AppSection) -> AnyView
    typealias ObjectBuilder = (ObjectID) -> AnyView
    typealias WorkbenchBuilder = (AppRouter) -> AnyView

    private let sectionBuilder: SectionBuilder
    private let objectBuilder: ObjectBuilder
    private let workbenchBuilder: WorkbenchBuilder

    init(
        sectionBuilder: @escaping SectionBuilder,
        objectBuilder: @escaping ObjectBuilder,
        workbenchBuilder: @escaping WorkbenchBuilder
    ) {
        self.sectionBuilder = sectionBuilder
        self.objectBuilder = objectBuilder
        self.workbenchBuilder = workbenchBuilder
    }

    func destination(for section: AppSection) -> AnyView { sectionBuilder(section) }
    func destination(for objectID: ObjectID) -> AnyView { objectBuilder(objectID) }
    func workbench(router: AppRouter) -> AnyView { workbenchBuilder(router) }

    static let unconfigured = AppFeatureRegistry(
        sectionBuilder: { section in AnyView(UnavailableFeatureScreen(section: section)) },
        objectBuilder: { objectID in AnyView(UnavailableObjectScreen(objectID: objectID)) },
        workbenchBuilder: { router in AnyView(WorkspaceUnavailableScreen(router: router)) }
    )

    static func configured(_ composition: AppFeatureComposition) -> AppFeatureRegistry {
        let destinations = AppFeatureDestinationFactory(composition: composition)
        return AppFeatureRegistry(
            sectionBuilder: destinations.sectionDestination,
            objectBuilder: destinations.objectDestination,
            workbenchBuilder: destinations.workbenchDestination
        )
    }
}

@MainActor
private struct AppFeatureDestinationFactory {
    let composition: AppFeatureComposition

    func workbenchDestination(router: AppRouter) -> AnyView {
        let destinations = self
        return AnyView(
            InfrastructureWorkbenchScreen(
                router: router,
                inventory: composition.inventory,
                topology: composition.topology,
                ipam: composition.ipam,
                trace: composition.trace,
                sectionDestination: { section in destinations.sectionDestination(for: section) }
            ))
    }

    func sectionDestination(for section: AppSection) -> AnyView {
        switch section {
        case .explore, .racks, .trace, .scan:
            return primaryDestination(for: section)
        case .floorPlans, .workOrders, .ipam, .importExport:
            return workspaceDestination(for: section)
        case .templates, .reports, .audit, .administration, .reconciliation, .labels:
            return administrationDestination(for: section)
        }
    }

    func objectDestination(for objectID: ObjectID) -> AnyView {
        AnyView(InventoryObjectRouteScreen(model: composition.inventory, objectID: objectID))
    }

    private func primaryDestination(for section: AppSection) -> AnyView {
        switch section {
        case .explore:
            return AnyView(InventoryExploreScreen(model: composition.inventory))
        case .racks:
            return AnyView(TopologyWorkspaceScreen(model: composition.topology))
        case .trace:
            return AnyView(TraceStartScreen(model: composition.trace, inventory: composition.inventory))
        case .scan:
            return AnyView(ScanIntakeScreen(model: composition.scan))
        default:
            return unavailableDestination(for: section)
        }
    }

    private func workspaceDestination(for section: AppSection) -> AnyView {
        switch section {
        case .floorPlans:
            return floorPlansDestination()
        case .workOrders:
            return workOrdersDestination()
        case .ipam:
            return AnyView(IPAMWorkspaceScreen(model: composition.ipam))
        case .importExport:
            return transferDestination()
        default:
            return unavailableDestination(for: section)
        }
    }

    private func administrationDestination(for section: AppSection) -> AnyView {
        switch section {
        case .templates:
            return AnyView(TemplateCatalogScreen(model: composition.templates))
        case .labels:
            return AnyView(LabelSheetScreen(model: composition.labels))
        case .reconciliation:
            return AnyView(
                ReconciliationScreen(
                    model: composition.reconciliation,
                    authorization: composition.operationsAuthorization
                ))
        case .reports, .audit:
            return AnyView(
                OperationsScreen(
                    model: composition.operations,
                    mode: section == .reports ? .reports : .audit,
                    exportAuthorization: composition.auditExportAuthorization
                ))
        case .administration:
            return AnyView(
                AdministrationScreen(
                    model: composition.administration,
                    shareMetadata: composition.workspaceShareMetadata,
                    onInvitationPrepared: composition.onWorkspaceInvitationPrepared
                ))
        default:
            return unavailableDestination(for: section)
        }
    }

    private func floorPlansDestination() -> AnyView {
        AnyView(
            FloorPlansScreen(
                model: composition.floorPlans,
                authorization: composition.operationsAuthorization,
                importSource: composition.floorPlanImportSource,
                attachmentAuthorization: composition.attachmentAuthorization,
                previewAuthorization: composition.floorPlanPreviewAuthorization,
                objectDestination: objectDestination,
                inventory: composition.inventory
            ))
    }

    private func workOrdersDestination() -> AnyView {
        AnyView(
            WorkOrdersScreen(
                model: composition.workOrders,
                authorization: composition.operationsAuthorization,
                evidenceSource: composition.workOrderEvidenceSource,
                evidenceAuthorization: composition.workOrderEvidenceAuthorization,
                cancellationReleaseAuthorization: composition.cancellationReleaseAuthorization
            ))
    }

    private func transferDestination() -> AnyView {
        AnyView(
            TransferScreen(
                model: composition.transfer,
                importDocument: composition.csvImportDocument,
                importAuthorization: composition.importAuthorization,
                csvExportAuthorization: composition.csvExportAuthorization,
                csvExportDestination: composition.csvExportDestination,
                exportAuthorization: composition.archiveExportAuthorization,
                restoreSource: composition.archiveRestoreSource,
                archivePackageSource: composition.archivePackageSource,
                restoreAuthorization: composition.archiveRestoreAuthorization
            ))
    }

    private func unavailableDestination(for section: AppSection) -> AnyView {
        AnyView(UnavailableFeatureScreen(section: section))
    }
}

private struct InventoryObjectRouteScreen: View {
    let model: InventoryExploreModel
    let objectID: ObjectID

    var body: some View {
        InventoryDetailPanel(model: model)
            .task(id: objectID) { await model.select(objectID) }
    }
}

private struct UnavailableFeatureScreen: View {
    let section: AppSection

    var body: some View {
        WorkspaceConnectionGuidance(section: section)
    }
}

private struct UnavailableObjectScreen: View {
    let objectID: ObjectID

    var body: some View {
        ContentUnavailableView {
            Label("Object unavailable", systemImage: "qrcode.viewfinder")
        } description: {
            Text("Connect to your organization's workspace to open this object.")
            Text(objectID.description).font(.caption.monospaced()).textSelection(.enabled)
        }
        .navigationTitle("Object")
    }
}
