import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

enum TemplateAdministrationPolicy: Equatable, Sendable {
    case allowed
    case readOnly
    case denied(String)
}

struct TemplateCatalogItem: Identifiable, Equatable, Sendable {
    let id: ObjectID
    let name: String
    let version: Int
    let portCount: Int
    let moduleCount: Int
    let validationSummary: String
}

struct TemplateMigrationImpactSnapshot: Identifiable, Equatable, Sendable {
    let id: ObjectID
    let action: TemplatePortMigrationAction
    let requiresCableReview: Bool
    let explanation: String
}

struct TemplateChangeRequest: Equatable, Sendable {
    let title: String
    let ticketID: String
    let notes: String
    /// The complete immutable target, including its version and field schema.
    let targetTemplate: DeviceType
    let requestKind: RequestKind

    enum RequestKind: Equatable, Sendable {
        case create
        case clone(sourceTemplateID: ObjectID)
        case newVersion(sourceTemplateID: ObjectID)
        /// The instantiation result is complete and immutable before it enters
        /// the work-order lifecycle; the UI never stages a generic device op.
        case instantiate(DeviceInstantiation)
        /// Decisions include both snapshots, preventing later catalog changes
        /// from altering an already-reviewed migration request.
        case migration(plans: [DeviceTemplateMigrationPlan])
    }
}

struct ModuleTemplateChangeRequest: Equatable, Sendable {
    let title: String
    let ticketID: String
    let notes: String
    let targetTemplate: ModuleTemplate
    let requestKind: RequestKind

    enum RequestKind: Equatable, Sendable {
        case create
        case clone(sourceTemplateID: ObjectID)
        case newVersion(sourceTemplateID: ObjectID)
    }
}

enum TemplateCatalogQueryError: LocalizedError, Sendable {
    case detailUnavailable
    case migrationPlanningUnavailable

    var errorDescription: String? {
        switch self {
        case .detailUnavailable: "The selected template's complete definition is not available."
        case .migrationPlanningUnavailable: "Detailed migration plans are not available."
        }
    }
}

protocol TemplateCatalogQuerying: Sendable {
    func catalog(in namespace: PersistenceNamespace) async throws -> [TemplateCatalogItem]
    func migrationImpact(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [TemplateMigrationImpactSnapshot]
    func template(id: ObjectID, in namespace: PersistenceNamespace) async throws -> DeviceType
    func migrationPlans(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [DeviceTemplateMigrationPlan]
    func moduleTemplates(in namespace: PersistenceNamespace) async throws -> [ModuleTemplate]
}

extension TemplateCatalogQuerying {
    // These compatibility defaults make unavailable detail explicit rather
    // than fabricating an editable template from a catalog summary.
    func template(id: ObjectID, in namespace: PersistenceNamespace) async throws -> DeviceType {
        throw TemplateCatalogQueryError.detailUnavailable
    }

    func migrationPlans(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [DeviceTemplateMigrationPlan] {
        throw TemplateCatalogQueryError.migrationPlanningUnavailable
    }

    func moduleTemplates(in namespace: PersistenceNamespace) async throws -> [ModuleTemplate] { [] }
}

protocol TemplateChangeRequesting: Sendable {
    /// Staging is the only mutation boundary for every template action.
    func stage(_ request: TemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
    func stage(_ request: ModuleTemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
}

extension TemplateChangeRequesting {
    func stage(_ request: ModuleTemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        throw TemplateCatalogQueryError.detailUnavailable
    }
}

@MainActor
@Observable
final class TemplateCatalogModel {
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
        do {
            async let catalog = query.catalog(in: account.namespace)
            async let modules = query.moduleTemplates(in: account.namespace)
            items = try await catalog
            moduleTemplates = try await modules
            state = items.isEmpty ? .empty : .ready
        } catch is CancellationError {
            return
        } catch {
            state = .offline("Template catalog is unavailable offline.")
        }
    }

    func loadDetails(for id: ObjectID) async {
        selectedTemplate = nil
        impacts = []
        migrationPlans = []
        detailMessage = nil

        async let templateResult = query.template(id: id, in: account.namespace)
        async let impactResult = query.migrationImpact(templateID: id, in: account.namespace)
        async let planResult = query.migrationPlans(templateID: id, in: account.namespace)

        do {
            selectedTemplate = try await templateResult
        } catch is CancellationError {
            return
        } catch {
            detailMessage = error.localizedDescription
        }

        do {
            impacts = try await impactResult
        } catch is CancellationError {
            return
        } catch {
            detailMessage = detailMessage ?? "Migration impact could not be loaded."
        }

        do {
            migrationPlans = try await planResult
        } catch is CancellationError {
            return
        } catch {
            detailMessage = detailMessage ?? error.localizedDescription
        }
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
