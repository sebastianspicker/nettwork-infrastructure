import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

@MainActor
@Observable
final class TemplateCatalogModel {
    private var loadGeneration: UInt64 = 0
    private var detailGeneration: UInt64 = 0
    private let query: any TemplateCatalogQuerying
    private let requests: any TemplateChangeRequesting
    private let account: AccountContext
    private let onStagedWorkOrder: (@MainActor (ObjectID) async -> Void)?

    let policy: TemplateAdministrationPolicy
    private(set) var state: InventoryPresentationState = .loading
    private(set) var items: [TemplateCatalogItem] = []
    private(set) var impacts: [TemplateMigrationImpactSnapshot] = []
    private(set) var selectedTemplate: DeviceType?
    private(set) var migrationPlans: [DeviceTemplateMigrationPlan] = []
    private(set) var moduleTemplates: [ModuleTemplate] = []
    private(set) var detailMessage: String?
    private(set) var lastStagedWorkOrderID: ObjectID?

    init(
        account: AccountContext,
        policy: TemplateAdministrationPolicy,
        query: any TemplateCatalogQuerying,
        requests: any TemplateChangeRequesting,
        onStagedWorkOrder: (@MainActor (ObjectID) async -> Void)? = nil
    ) {
        self.account = account
        self.policy = policy
        self.query = query
        self.requests = requests
        self.onStagedWorkOrder = onStagedWorkOrder
    }

    var canRequestChanges: Bool {
        if case .allowed = policy { return true }
        return false
    }

    var permissionMessage: String {
        switch policy {
        case .allowed: "Authorized template administrators can stage work-order requests."
        case .readOnly: "Your role can review templates, but cannot stage template changes."
        case .denied(let reason): reason
        }
    }

    func load() async {
        guard !Task.isCancelled else { return }
        loadGeneration &+= 1
        let generation = loadGeneration
        do {
            async let catalog = query.catalog(in: account.namespace)
            async let modules = query.moduleTemplates(in: account.namespace)
            let loaded = try await (catalog, modules)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            items = loaded.0
            moduleTemplates = loaded.1
            state = items.isEmpty ? .empty : .ready
        } catch is CancellationError {
            return
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            state = .offline("Template catalog is unavailable offline.")
        }
    }

    func loadDetails(for id: ObjectID) async {
        guard !Task.isCancelled else { return }
        detailGeneration &+= 1
        let generation = detailGeneration
        selectedTemplate = nil
        impacts = []
        migrationPlans = []
        detailMessage = nil

        let query = self.query
        let namespace = account.namespace
        async let templateResult = Self.readDetail { try await query.template(id: id, in: namespace) }
        async let impactResult = Self.readDetail { try await query.migrationImpact(templateID: id, in: namespace) }
        async let planResult = Self.readDetail { try await query.migrationPlans(templateID: id, in: namespace) }

        guard publishDetail(await templateResult, generation: generation, message: { $0.localizedDescription }, update: { selectedTemplate = $0 }) else {
            return
        }
        guard publishDetail(await impactResult, generation: generation, message: { _ in "Migration impact could not be loaded." }, update: { impacts = $0 })
        else {
            return
        }
        _ = publishDetail(await planResult, generation: generation, message: { $0.localizedDescription }, update: { migrationPlans = $0 })
    }

    nonisolated private static func readDetail<Value: Sendable>(
        _ operation: @Sendable () async throws -> Value
    ) async -> Result<Value, any Error> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error)
        }
    }

    private func publishDetail<Value>(
        _ result: Result<Value, any Error>, generation: UInt64,
        message: (any Error) -> String, update: (Value) -> Void
    ) -> Bool {
        guard generation == detailGeneration, !Task.isCancelled else { return false }
        switch result {
        case .success(let value):
            update(value)
        case .failure(let error):
            guard !(error is CancellationError) else { return false }
            detailMessage = detailMessage ?? message(error)
        }
        return true
    }

    @discardableResult
    func stage(_ request: TemplateChangeRequest) async -> ObjectID? {
        guard canRequestChanges else {
            state = .permissionDenied(permissionMessage)
            return nil
        }

        do {
            let workOrderID = try await requests.stage(request, in: account.namespace)
            lastStagedWorkOrderID = workOrderID
            state = .pending("Template change is staged for policy and audit review.")
            await onStagedWorkOrder?(workOrderID)
            return workOrderID
        } catch is CancellationError {
            return nil
        } catch {
            state = .conflict("The template request conflicts with the current catalog version.")
            return nil
        }
    }

    @discardableResult
    func stage(_ request: ModuleTemplateChangeRequest) async -> ObjectID? {
        guard canRequestChanges else {
            state = .permissionDenied(permissionMessage)
            return nil
        }
        do {
            let workOrderID = try await requests.stage(request, in: account.namespace)
            lastStagedWorkOrderID = workOrderID
            state = .pending("Module template change is staged for policy and audit review.")
            await onStagedWorkOrder?(workOrderID)
            return workOrderID
        } catch is CancellationError {
            return nil
        } catch {
            state = .conflict("The module template request conflicts with the current catalog version.")
            return nil
        }
    }
}
