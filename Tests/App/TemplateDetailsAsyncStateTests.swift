import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

@MainActor
final class TemplateDetailsAsyncStateTests: XCTestCase {
    func testEveryDetailPublicationAndErrorUsesTheLatestSelection() async {
        for failing in [false, true] {
            for boundary in 0..<3 {
                await verifyObsoleteDetails(boundary: boundary, failing: failing)
            }
        }
    }

    private func verifyObsoleteDetails(boundary: Int, failing: Bool) async {
        let query = ControlledTemplateDetailsQuery()
        let model = makeModel(query)
        let old = DeviceType(name: "Old", kind: .switchDevice)
        let newest = DeviceType(name: "Newest", kind: .switchDevice)
        let first = await startObsoleteDetails(model, query: query, template: old, boundary: boundary)
        let second = Task { await model.loadDetails(for: newest.id) }
        await query.waitForDetails(2)
        let latestImpact = impact(newest.id)
        let latestPlan = plan(newest)
        await query.completeDetails(2, template: newest, impacts: [latestImpact], plans: [latestPlan])
        await second.value
        if failing {
            if boundary == 0 { await query.definitions.fail(1) }
            if boundary <= 1 { await query.impacts.fail(1) }
            await query.plans.fail(1)
        } else {
            if boundary == 0 { await query.definitions.succeed(1, with: old) }
            if boundary < 2 { await query.impacts.succeed(1, with: [impact(old.id)]) }
            await query.plans.succeed(1, with: [plan(old)])
        }
        await first.value
        XCTAssertEqual(model.selectedTemplate, newest)
        XCTAssertEqual(model.impacts, [latestImpact])
        XCTAssertEqual(model.migrationPlans, [latestPlan])
        XCTAssertNil(model.detailMessage)
    }

    func testPartialDetailFailureRetainsIndependentImpactAndPlanResults() async {
        let query = ControlledTemplateDetailsQuery()
        let model = makeModel(query)
        let template = DeviceType(name: "Current", kind: .switchDevice)
        let selection = Task { await model.loadDetails(for: template.id) }
        await query.waitForDetails(1)
        let loadedImpact = impact(template.id)
        let loadedPlan = plan(template)
        await query.definitions.fail(1)
        await query.impacts.succeed(1, with: [loadedImpact])
        await query.plans.succeed(1, with: [loadedPlan])
        await selection.value
        XCTAssertNil(model.selectedTemplate)
        XCTAssertEqual(model.impacts, [loadedImpact])
        XCTAssertEqual(model.migrationPlans, [loadedPlan])
        XCTAssertNotNil(model.detailMessage)
    }

    func testCancelledDetailsCannotPublishEvenWhenQueryIgnoresCancellation() async {
        let query = ControlledTemplateDetailsQuery()
        let model = makeModel(query)
        let template = DeviceType(name: "Cancelled", kind: .switchDevice)
        let selection = Task { await model.loadDetails(for: template.id) }
        await query.waitForDetails(1)
        selection.cancel()
        await query.completeDetails(1, template: template, impacts: [impact(template.id)], plans: [plan(template)])
        await selection.value
        XCTAssertNil(model.selectedTemplate)
        XCTAssertTrue(model.impacts.isEmpty)
        XCTAssertTrue(model.migrationPlans.isEmpty)
        XCTAssertNil(model.detailMessage)
    }

    func testCatalogPublishesOnlyCompleteLatestResultAndIgnoresStaleFailure() async {
        let query = ControlledTemplateDetailsQuery()
        let model = makeModel(query)
        let first = Task { await model.load() }
        await query.waitForCatalog(1)
        let second = Task { await model.load() }
        await query.waitForCatalog(2)
        let item = TemplateCatalogItem(id: ObjectID(), name: "Newest", version: 1, portCount: 0, moduleCount: 0, validationSummary: "Valid")
        let module = ModuleTemplate(name: "Newest module", ports: [])
        await query.catalogs.succeed(2, with: [item])
        // No catalog should be visible before its matching module result.
        XCTAssertTrue(model.items.isEmpty)
        await query.modules.succeed(2, with: [module])
        await second.value
        await query.catalogs.succeed(1, with: [])
        await query.modules.fail(1)
        await first.value
        XCTAssertEqual(model.items, [item])
        XCTAssertEqual(model.moduleTemplates, [module])
        XCTAssertEqual(model.state, .ready)
    }

    private func startObsoleteDetails(
        _ model: TemplateCatalogModel, query: ControlledTemplateDetailsQuery, template: DeviceType, boundary: Int
    ) async -> Task<Void, Never> {
        let selection = Task { await model.loadDetails(for: template.id) }
        await query.waitForDetails(1)
        if boundary > 0 {
            await query.definitions.succeed(1, with: template)
            await waitUntil { model.selectedTemplate == template }
        }
        if boundary > 1 {
            await query.impacts.succeed(1, with: [impact(template.id)])
            await waitUntil { !model.impacts.isEmpty }
        }
        return selection
    }

    private func makeModel(_ query: ControlledTemplateDetailsQuery) -> TemplateCatalogModel {
        TemplateCatalogModel(account: asyncFeatureTestAccount(), policy: .allowed, query: query, requests: AsyncTemplateRequestStub())
    }

    private func impact(_ id: ObjectID) -> TemplateMigrationImpactSnapshot {
        TemplateMigrationImpactSnapshot(id: id, action: .retain, requiresCableReview: false, explanation: "Retain")
    }

    private func plan(_ template: DeviceType) -> DeviceTemplateMigrationPlan {
        DeviceTemplateMigrationPlan(
            deviceID: ObjectID(), sourceSnapshot: DeviceTemplateSnapshot(template: template),
            targetSnapshot: DeviceTemplateSnapshot(template: template), portImpacts: []
        )
    }

    private func waitUntil(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("The preceding controlled detail was not published.")
    }
}

private struct ControlledTemplateDetailsQuery: TemplateCatalogQuerying {
    let definitions = ControlledFeatureRequest<DeviceType>()
    let impacts = ControlledFeatureRequest<[TemplateMigrationImpactSnapshot]>()
    let plans = ControlledFeatureRequest<[DeviceTemplateMigrationPlan]>()
    let catalogs = ControlledFeatureRequest<[TemplateCatalogItem]>()
    let modules = ControlledFeatureRequest<[ModuleTemplate]>()

    func template(id: ObjectID, in namespace: PersistenceNamespace) async throws -> DeviceType { try await definitions.perform() }
    func migrationImpact(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [TemplateMigrationImpactSnapshot] {
        try await impacts.perform()
    }
    func migrationPlans(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [DeviceTemplateMigrationPlan] {
        try await plans.perform()
    }
    func catalog(in namespace: PersistenceNamespace) async throws -> [TemplateCatalogItem] { try await catalogs.perform() }
    func moduleTemplates(in namespace: PersistenceNamespace) async throws -> [ModuleTemplate] { try await modules.perform() }

    func waitForDetails(_ index: Int) async {
        await definitions.waitForRequest(index)
        await impacts.waitForRequest(index)
        await plans.waitForRequest(index)
    }

    func waitForCatalog(_ index: Int) async {
        await catalogs.waitForRequest(index)
        await modules.waitForRequest(index)
    }

    func completeDetails(_ index: Int, template: DeviceType, impacts: [TemplateMigrationImpactSnapshot], plans: [DeviceTemplateMigrationPlan]) async {
        await definitions.succeed(index, with: template)
        await self.impacts.succeed(index, with: impacts)
        await self.plans.succeed(index, with: plans)
    }
}

private struct AsyncTemplateRequestStub: TemplateChangeRequesting {
    func stage(_ request: TemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID { ObjectID() }
}
