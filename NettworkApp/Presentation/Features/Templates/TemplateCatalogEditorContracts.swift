import FeatureContracts
import Foundation
import ImportExport
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

enum TemplateSheetDestination: Identifiable {
    case editor(TemplateEditorRoute)
    case migration(template: DeviceType, plans: [DeviceTemplateMigrationPlan])
    case instantiate(DeviceType)
    case moduleEditor(ModuleTemplateEditorRoute)

    var id: String {
        switch self {
        case .editor(let route): route.id
        case .migration(let template, _): "migration-\(template.id.description)-\(template.version)"
        case .instantiate(let template): "instantiate-\(template.id.description)"
        case .moduleEditor(let route): route.id
        }
    }
}

enum TemplateEditorRoute: Identifiable {
    case create
    case clone(DeviceType)
    case newVersion(DeviceType)

    var id: String {
        switch self {
        case .create: "create"
        case .clone(let source): "clone-\(source.id.description)"
        case .newVersion(let source): "version-\(source.id.description)-\(source.version)"
        }
    }

    var title: String {
        switch self {
        case .create: "New template"
        case .clone: "Clone template"
        case .newVersion: "New template version"
        }
    }

    var requestKind: TemplateChangeRequest.RequestKind {
        switch self {
        case .create: .create
        case .clone(let source): .clone(sourceTemplateID: source.id)
        case .newVersion(let source): .newVersion(sourceTemplateID: source.id)
        }
    }

    func initialTemplate() -> DeviceType {
        switch self {
        case .create:
            return DeviceType(name: "", kind: .generic)
        case .clone(let source):
            let portIDs = Dictionary(uniqueKeysWithValues: source.portTemplates.map { ($0.id, ObjectID()) })
            return (try? TemplateCatalog.clone(source, id: ObjectID(), portIDs: portIDs)) ?? source
        case .newVersion(let source):
            return (try? TemplateCatalog.nextVersion(of: source)) ?? source
        }
    }
}

enum ModuleTemplateEditorRoute: Identifiable {
    case create
    case clone(ModuleTemplate)
    case newVersion(ModuleTemplate)

    var id: String {
        switch self {
        case .create: "module-create"
        case .clone(let source): "module-clone-\(source.id.description)"
        case .newVersion(let source): "module-version-\(source.id.description)-\(source.version)"
        }
    }

    var title: String {
        switch self {
        case .create: "New module template"
        case .clone: "Clone module template"
        case .newVersion: "New module template version"
        }
    }

    var requestKind: ModuleTemplateChangeRequest.RequestKind {
        switch self {
        case .create: .create
        case .clone(let source): .clone(sourceTemplateID: source.id)
        case .newVersion(let source): .newVersion(sourceTemplateID: source.id)
        }
    }

    func initialTemplate() -> ModuleTemplate {
        switch self {
        case .create:
            return ModuleTemplate(name: "", ports: [])
        case .clone(let source):
            let ids = Dictionary(uniqueKeysWithValues: source.ports.map { ($0.id, ObjectID()) })
            return (try? TemplateCatalog.clone(source, id: ObjectID(), portIDs: ids)) ?? source
        case .newVersion(let source):
            return (try? TemplateCatalog.nextVersion(of: source)) ?? source
        }
    }
}
