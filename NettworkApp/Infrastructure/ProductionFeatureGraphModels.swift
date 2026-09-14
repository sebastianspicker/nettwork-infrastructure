import NetworkModel
import WorkspaceChangeControl

@MainActor
struct ProductionFeatureGraphServices {
    let reads: SwiftDataFeatureReadAdapter
    let operations: SwiftDataOperationsAdapter
    let workOrders: OperationsFeatureViewModel
    let drafts: AuthorizedWorkOrderDraftAdapter
    let scan: ScanIntakeModel
}

@MainActor
struct ProductionFeatureGraphModels {
    let inventory: InventoryExploreModel
    let topology: TopologyWorkspaceModel
    let trace: TraceInspectionModel
    let floorPlans: FloorPlanViewModel
    let ipam: IPAMWorkspaceModel
    let templates: TemplateCatalogModel
    let operations: OperationsReadViewModel
    let administration: WorkspaceAdministrationViewModel
    let reconciliation: ReconciliationViewModel
    let transfer: TransferFeatureViewModel
    let labels: LabelSheetModel
}

extension ProductionFeatureGraphInput: AppFeatureOptionalCapabilitiesProviding {}

@MainActor
extension ProductionFeatureGraphFactory {
    static func makeFeatureGraphServices(
        _ input: ProductionFeatureGraphInput
    ) -> ProductionFeatureGraphServices {
        let enumerator = SwiftDataMirrorRecordEnumerator(persistence: input.persistence)
        let reads = SwiftDataFeatureReadAdapter(
            account: input.account, persistence: input.persistence, reader: enumerator,
            currentAuthorizationContext: input.currentAuthorizationContext, operationBoundary: input.operationBoundary)
        let operations = SwiftDataOperationsAdapter(
            account: input.account, persistence: input.persistence, reader: enumerator,
            mutations: input.mutations, synchronizer: input.synchronizer, workspaceAccessReader: input.workspaceAccess,
            telemetryExternalSignalProvider: input.telemetryExternalSignalProvider, operationBoundary: input.operationBoundary)
        let relay = ScanModelRelay()
        let capture = input.scanCapture { objectID in relay.receive(objectID) }
        let scan = ScanIntakeModel(account: input.account, capture: capture, resolver: reads)
        relay.model = scan
        let workOrders = OperationsFeatureViewModel(service: operations, evidenceService: input.attachmentEvidenceService)
        let drafts = AuthorizedWorkOrderDraftAdapter(
            account: input.account, authority: input.mutations,
            onStagedWorkOrder: { id in await workOrders.registerStagedDraft(id: id) })
        return ProductionFeatureGraphServices(reads: reads, operations: operations, workOrders: workOrders, drafts: drafts, scan: scan)
    }

    static func makeFeatureGraphModels(
        _ input: ProductionFeatureGraphInput,
        services: ProductionFeatureGraphServices
    ) -> ProductionFeatureGraphModels {
        let inventory = InventoryExploreModel(account: input.account, queryService: services.reads, historyStore: ScopedInventoryHistoryAdapter())
        let topology = TopologyWorkspaceModel(account: input.account, browser: services.reads, drafts: services.drafts)
        let trace = TraceInspectionModel(
            account: input.account, service: services.reads, identifierCopier: ProductionTraceIdentifierCopier(),
            drafts: services.drafts)
        let floorPlans = FloorPlanViewModel(
            floorID: input.floorID, anchors: input.floorPlanAnchors, labels: input.floorPlanLabels,
            service: input.floorPlanService, onStagedWorkOrder: { id in await services.workOrders.registerStagedDraft(id: id) })
        let ipam = IPAMWorkspaceModel(account: input.account, browser: services.reads, drafts: services.drafts)
        let templates = TemplateCatalogModel(account: input.account, policy: input.templatePolicy, query: services.reads, requests: services.drafts)
        let operations = OperationsReadViewModel(service: services.operations)
        let administration = WorkspaceAdministrationViewModel(service: input.administration)
        let reconciliation = ReconciliationViewModel(
            service: services.operations,
            onStagedWorkOrder: { id in await services.workOrders.registerStagedDraft(id: id) })
        let transfer = TransferFeatureViewModel(service: input.transferService, csvExporter: services.reads)
        let labels = LabelSheetModel(
            account: input.account, source: services.reads, generator: input.labelGenerator,
            exporter: input.labelExporter, printer: input.labelPrinter)
        return ProductionFeatureGraphModels(
            inventory: inventory, topology: topology, trace: trace, floorPlans: floorPlans, ipam: ipam,
            templates: templates, operations: operations, administration: administration, reconciliation: reconciliation, transfer: transfer, labels: labels)
    }

    static func makeFeatureComposition(
        _ input: ProductionFeatureGraphInput,
        services: ProductionFeatureGraphServices,
        models: ProductionFeatureGraphModels
    ) -> AppFeatureComposition {
        AppFeatureComposition(
            inventory: models.inventory,
            topology: models.topology,
            trace: models.trace,
            scan: services.scan,
            workOrders: services.workOrders,
            floorPlans: models.floorPlans,
            ipam: models.ipam,
            templates: models.templates,
            operations: models.operations,
            administration: models.administration,
            reconciliation: models.reconciliation,
            transfer: models.transfer,
            labels: models.labels,
            operationsAuthorization: input.operationsAuthorization,
            cancellationReleaseAuthorization: input.cancellationReleaseAuthorization,
            workOrderEvidenceSource: input.workOrderEvidenceSource,
            workOrderEvidenceAuthorization: input.workOrderEvidenceAuthorization,
            optionalCapabilities: AppFeatureOptionalCapabilities(source: input)
        )
    }
}
