import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

final class TopologyHierarchyIndexTests: XCTestCase {
    func testIndexPreservesRootsOrphansIdentityAndLocalizedChildOrder() {
        let root = hierarchyNode(name: "Root")
        let orphan = hierarchyNode(parentID: ObjectID(), name: "Orphan")
        let childB = hierarchyNode(parentID: root.id, name: "Port 10")
        let childA = hierarchyNode(parentID: root.id, name: "Port 2")
        let index = TopologyHierarchyIndex(nodes: [childB, orphan, root, childA])

        XCTAssertEqual(Set(index.roots.map(\.id)), Set([root.id, orphan.id]))
        XCTAssertEqual(index.children(of: root.id).map(\.id), [childA.id, childB.id])
        XCTAssertEqual(index.nodes.map(\.id), [childB.id, orphan.id, root.id, childA.id])
    }

    @MainActor
    func testModelPublishesHierarchyIndexOnlyAfterSuccessfulCombinedLoad() async {
        let root = hierarchyNode(name: "Root")
        let child = hierarchyNode(parentID: root.id, name: "Child")
        let browser = TopologyBrowserFixture(hierarchy: [child, root])
        let model = TopologyWorkspaceModel(
            account: inventoryTestAccountForTopology(),
            browser: browser,
            drafts: TopologyDraftFixture()
        )

        let firstLoad = await model.load()
        XCTAssertTrue(firstLoad)
        XCTAssertEqual(model.hierarchyIndex.roots.map(\.id), [root.id])
        XCTAssertEqual(model.hierarchyIndex.children(of: root.id).map(\.id), [child.id])

        await browser.setFailure(true)
        let failedLoad = await model.load()
        XCTAssertTrue(failedLoad)
        XCTAssertEqual(model.hierarchyIndex.roots.map(\.id), [root.id])
        XCTAssertEqual(model.hierarchyIndex.children(of: root.id).map(\.id), [child.id])
    }
}

private func hierarchyNode(parentID: ObjectID? = nil, name: String) -> TopologyHierarchyNode {
    TopologyHierarchyNode(
        id: ObjectID(),
        parentID: parentID,
        kind: .device,
        name: name,
        detail: "Device",
        childCount: 0,
        location: nil,
        rack: nil
    )
}

private actor TopologyBrowserFixture: TopologyBrowsing {
    private let nodes: [TopologyHierarchyNode]
    private var shouldFail = false

    init(hierarchy: [TopologyHierarchyNode]) { nodes = hierarchy }

    func setFailure(_ value: Bool) { shouldFail = value }

    func hierarchy(in namespace: PersistenceNamespace) async throws -> [TopologyHierarchyNode] {
        if shouldFail { throw FixtureError.failed }
        return nodes
    }

    func racks(in namespace: PersistenceNamespace) async throws -> [RackElevationSnapshot] {
        if shouldFail { throw FixtureError.failed }
        return []
    }

    func deviceDecommissionSnapshot(for deviceID: ObjectID, in namespace: PersistenceNamespace) async throws -> DeviceDecommissionSnapshot {
        throw FixtureError.failed
    }
}

private actor TopologyDraftFixture: TopologyWorkOrderDrafting {
    func stage(_ request: TopologyWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID {
        ObjectID()
    }
}

private enum FixtureError: Error { case failed }

private func inventoryTestAccountForTopology() -> AccountContext {
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
