import Foundation
import NetworkModel
import WorkspaceChangeControl

public enum TemplateAdministrationPolicy: Equatable, Sendable {
    case allowed
    case readOnly
    case denied(String)
}

public struct TemplateCatalogItem: Identifiable, Equatable, Sendable {
    public let id: ObjectID
    public let name: String
    public let version: Int
    public let portCount: Int
    public let moduleCount: Int
    public let validationSummary: String

    public init(id: ObjectID, name: String, version: Int, portCount: Int, moduleCount: Int, validationSummary: String) {
        self.id = id
        self.name = name
        self.version = version
        self.portCount = portCount
        self.moduleCount = moduleCount
        self.validationSummary = validationSummary
    }
}

public struct TemplateMigrationImpactSnapshot: Identifiable, Equatable, Sendable {
    public let id: ObjectID
    public let action: TemplatePortMigrationAction
    public let requiresCableReview: Bool
    public let explanation: String

    public init(id: ObjectID, action: TemplatePortMigrationAction, requiresCableReview: Bool, explanation: String) {
        self.id = id
        self.action = action
        self.requiresCableReview = requiresCableReview
        self.explanation = explanation
    }
}

public struct TemplateChangeRequest: Equatable, Sendable {
    public let title: String
    public let ticketID: String
    public let notes: String
    /// The complete immutable target, including its version and field schema.
    public let targetTemplate: DeviceType
    public let requestKind: RequestKind

    public init(title: String, ticketID: String, notes: String, targetTemplate: DeviceType, requestKind: RequestKind) {
        self.title = title
        self.ticketID = ticketID
        self.notes = notes
        self.targetTemplate = targetTemplate
        self.requestKind = requestKind
    }

    public enum RequestKind: Equatable, Sendable {
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

public struct ModuleTemplateChangeRequest: Equatable, Sendable {
    public let title: String
    public let ticketID: String
    public let notes: String
    public let targetTemplate: ModuleTemplate
    public let requestKind: RequestKind

    public init(title: String, ticketID: String, notes: String, targetTemplate: ModuleTemplate, requestKind: RequestKind) {
        self.title = title
        self.ticketID = ticketID
        self.notes = notes
        self.targetTemplate = targetTemplate
        self.requestKind = requestKind
    }

    public enum RequestKind: Equatable, Sendable {
        case create
        case clone(sourceTemplateID: ObjectID)
        case newVersion(sourceTemplateID: ObjectID)
    }
}

public enum TemplateCatalogQueryError: LocalizedError, Sendable {
    case detailUnavailable
    case migrationPlanningUnavailable

    public var errorDescription: String? {
        switch self {
        case .detailUnavailable: "The selected template's complete definition is not available."
        case .migrationPlanningUnavailable: "Detailed migration plans are not available."
        }
    }
}

public protocol TemplateCatalogQuerying: Sendable {
    func catalog(in namespace: PersistenceNamespace) async throws -> [TemplateCatalogItem]
    func migrationImpact(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [TemplateMigrationImpactSnapshot]
    func template(id: ObjectID, in namespace: PersistenceNamespace) async throws -> DeviceType
    func migrationPlans(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [DeviceTemplateMigrationPlan]
    func moduleTemplates(in namespace: PersistenceNamespace) async throws -> [ModuleTemplate]
}

extension TemplateCatalogQuerying {
    // These compatibility defaults make unavailable detail explicit rather
    // than fabricating an editable template from a catalog summary.
    public func template(id: ObjectID, in namespace: PersistenceNamespace) async throws -> DeviceType {
        throw TemplateCatalogQueryError.detailUnavailable
    }

    public func migrationPlans(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [DeviceTemplateMigrationPlan] {
        throw TemplateCatalogQueryError.migrationPlanningUnavailable
    }

    public func moduleTemplates(in namespace: PersistenceNamespace) async throws -> [ModuleTemplate] { [] }
}

public protocol TemplateChangeRequesting: Sendable {
    /// Staging is the only mutation boundary for every template action.
    func stage(_ request: TemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
    func stage(_ request: ModuleTemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID
}

extension TemplateChangeRequesting {
    public func stage(_ request: ModuleTemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        throw TemplateCatalogQueryError.detailUnavailable
    }
}
