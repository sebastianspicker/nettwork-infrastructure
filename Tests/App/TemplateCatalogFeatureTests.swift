import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

@MainActor
final class TemplateCatalogFeatureTests: XCTestCase {
    func testStagingRetainsTheWorkOrderIDAndNotifiesTheOptionalCallback() async {
        let stagedID = ObjectID()
        let requests = TemplateRequestRecorder(stagedID: stagedID)
        let callback = StagedWorkOrderRecorder()
        let model = TemplateCatalogModel(
            account: templateAccount(),
            policy: .allowed,
            query: TemplateCatalogQueryStub(),
            requests: requests,
            onStagedWorkOrder: { id in await callback.receive(id) }
        )
        let target = DeviceType(name: "Edge switch", kind: .switchDevice)
        let request = TemplateChangeRequest(
            title: "Create edge switch template",
            ticketID: "CHG-42",
            notes: "Review before execution.",
            targetTemplate: target,
            requestKind: .create
        )

        let returnedID = await model.stage(request)
        let callbackID = await callback.lastID
        let stagedRequests = await requests.requests

        XCTAssertEqual(returnedID, stagedID)
        XCTAssertEqual(model.lastStagedWorkOrderID, stagedID)
        XCTAssertEqual(callbackID, stagedID)
        XCTAssertEqual(stagedRequests, [request])
    }

    func testReadOnlyPolicyCannotCallTheStagingSeam() async {
        let requests = TemplateRequestRecorder(stagedID: ObjectID())
        let model = TemplateCatalogModel(
            account: templateAccount(),
            policy: .readOnly,
            query: TemplateCatalogQueryStub(),
            requests: requests
        )
        let request = TemplateChangeRequest(
            title: "Create edge switch template",
            ticketID: "CHG-42",
            notes: "Review before execution.",
            targetTemplate: DeviceType(name: "Edge switch", kind: .switchDevice),
            requestKind: .create
        )

        let stagedID = await model.stage(request)
        let stagedRequests = await requests.requests

        XCTAssertNil(stagedID)
        XCTAssertEqual(stagedRequests, [])
        XCTAssertEqual(model.state, .permissionDenied(model.permissionMessage))
    }

    private func templateAccount() -> AccountContext {
        AccountContext(
            namespace: PersistenceNamespace(
                containerIdentifier: "iCloud.example.nettwork",
                cloudKitAccountRecordName: "account",
                workspaceID: ObjectID(),
                zoneName: "workspace",
                zoneOwnerRecordName: "owner",
                sessionGeneration: 1
            ),
            databaseScope: .ownerPrivate,
            sharePermission: .owner,
            verifiedAt: .now
        )
    }
}

private actor TemplateCatalogQueryStub: TemplateCatalogQuerying {
    func catalog(in namespace: PersistenceNamespace) async throws -> [TemplateCatalogItem] { [] }
    func migrationImpact(templateID: ObjectID, in namespace: PersistenceNamespace) async throws -> [TemplateMigrationImpactSnapshot] { [] }
}

private actor TemplateRequestRecorder: TemplateChangeRequesting {
    let stagedID: ObjectID
    private(set) var requests: [TemplateChangeRequest] = []

    init(stagedID: ObjectID) {
        self.stagedID = stagedID
    }

    func stage(_ request: TemplateChangeRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        requests.append(request)
        return stagedID
    }
}

private actor StagedWorkOrderRecorder {
    private(set) var lastID: ObjectID?

    func receive(_ id: ObjectID) {
        lastID = id
    }
}
