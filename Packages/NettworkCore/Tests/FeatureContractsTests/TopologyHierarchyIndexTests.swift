import FeatureContracts
import NetworkModel
import XCTest

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
