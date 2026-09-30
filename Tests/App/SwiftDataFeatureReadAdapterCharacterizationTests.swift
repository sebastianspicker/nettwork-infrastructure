import CloudSync
import ContentSafety
import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

/// Pins the read-model contract of the SwiftData feature adapter: verified
/// mirror records are mapped into inventory, IPAM and trace snapshots, and
/// every read is scoped to the adapter's account namespace. Records of a
/// different workspace in the same store are never visible.
final class SwiftDataFeatureReadAdapterCharacterizationTests: XCTestCase {
    private let topology = TopologyFixture()
    private let hierarchy = HierarchyFixture()

    func testSearchReturnsIndexedDevicesOfTheActiveNamespaceOnly() async throws {
        let fixture = try await ReadFixture.make(topology: topology, hierarchy: hierarchy)

        let results = try await fixture.adapter.search(InventorySearchQuery(text: "Switch", kinds: [.device]), in: fixture.namespace)

        XCTAssertEqual(results.map(\.id), [topology.switchDevice.id])
        XCTAssertEqual(results.first?.title, topology.switchDevice.name)
        XCTAssertEqual(results.first?.kind, .device)
        XCTAssertEqual(results.first?.isTombstoned, false)
    }

    func testDetailsResolveOnlyLiveObjectsOfTheNamespace() async throws {
        let fixture = try await ReadFixture.make(topology: topology, hierarchy: hierarchy)

        let details = try await fixture.adapter.details(for: topology.switchDevice.id, in: fixture.namespace)
        let foreign = try await fixture.adapter.details(for: fixture.foreignDevice.id, in: fixture.namespace)
        let resolved = try await fixture.adapter.resolve(topology.panelDevice.id, in: fixture.namespace)
        let unresolved = try await fixture.adapter.resolve(fixture.foreignDevice.id, in: fixture.namespace)

        XCTAssertEqual(details?.result.id, topology.switchDevice.id)
        XCTAssertEqual(details?.result.title, topology.switchDevice.name)
        XCTAssertNil(foreign)
        XCTAssertTrue(resolved)
        XCTAssertFalse(unresolved)
    }

    func testSiteOptionsListTheActiveSites() async throws {
        let fixture = try await ReadFixture.make(topology: topology, hierarchy: hierarchy)

        let sites = try await fixture.adapter.siteOptions(in: fixture.namespace)

        XCTAssertEqual(sites, [InventorySiteOption(id: hierarchy.site.id, title: hierarchy.site.name)])
    }

    func testEveryReadRejectsAnotherNamespace() async throws {
        let fixture = try await ReadFixture.make(topology: topology, hierarchy: hierarchy)
        let other = fixture.foreignNamespace

        await assertAdapterNamespaceMismatch { try await fixture.adapter.search(InventorySearchQuery(text: "Switch"), in: other) }
        await assertAdapterNamespaceMismatch { try await fixture.adapter.results(for: [fixture.foreignDevice.id], in: other) }
        await assertAdapterNamespaceMismatch { try await fixture.adapter.prefixes(in: other) }
        await assertAdapterNamespaceMismatch { try await fixture.adapter.siteOptions(in: other) }
    }

    func testPrefixesAndVRFsMapTheMirroredIPAMRecords() async throws {
        let fixture = try await ReadFixture.make(topology: topology, hierarchy: hierarchy)
        let ipam = fixture.ipam

        let vrfs = try await fixture.adapter.vrfs(in: fixture.namespace)
        let prefixes = try await fixture.adapter.prefixes(in: fixture.namespace)

        XCTAssertEqual(vrfs.map(\.id), [ipam.vrf.id])
        XCTAssertEqual(vrfs.first?.revision, ipam.vrf.revision)
        XCTAssertEqual(prefixes.map(\.id), [ipam.prefix.id])
        XCTAssertEqual(prefixes.first?.cidr, "192.0.2.0/24")
        XCTAssertEqual(prefixes.first?.vrfID, ipam.vrf.id)
        XCTAssertEqual(prefixes.first?.name, ipam.prefix.name)
        XCTAssertEqual(
            prefixes.first?.utilization, ipam.prefix.utilization(addresses: [fixture.assignedAddress, ipam.otherAddress]).consumedFraction)
        XCTAssertEqual(prefixes.first?.isPending, false)
    }

    func testAddressesOfAPrefixCarryTheirInterfaceAndResourceKey() async throws {
        let fixture = try await ReadFixture.make(topology: topology, hierarchy: hierarchy)
        let ipam = fixture.ipam

        let addresses = try await fixture.adapter.addresses(prefixID: ipam.prefix.id, in: fixture.namespace)
        let unknownPrefix = try await fixture.adapter.addresses(prefixID: ObjectID(), in: fixture.namespace)

        XCTAssertEqual(addresses.map(\.address), ["192.0.2.10", "192.0.2.20"])
        XCTAssertEqual(addresses.map(\.resourceKey), [.string(ipam.address.id), .string(ipam.otherAddress.id)])
        XCTAssertEqual(addresses.map(\.interfaceName), [ipam.interface.name, nil])
        XCTAssertEqual(unknownPrefix, [])
    }

    func testTraceFollowsTheInstalledCableInBothDirections() async throws {
        let fixture = try await ReadFixture.make(topology: topology, hierarchy: hierarchy)
        let cable = topology.patch()

        let forward = try await fixture.adapter.inspect(startingAt: topology.switchPort.id, direction: .forward, in: fixture.namespace)
        let reverse = try await fixture.adapter.inspect(startingAt: topology.switchPort.id, direction: .reverse, in: fixture.namespace)

        XCTAssertEqual(forward.startPortID, topology.switchPort.id)
        XCTAssertEqual(forward.branches.count, 1)
        XCTAssertEqual(forward.branches.first?.nodes.map(\.id), [topology.switchPort.id, topology.panelPort.id])
        XCTAssertEqual(forward.branches.first?.nodes.map(\.deviceName), [topology.switchDevice.name, topology.panelDevice.name])
        XCTAssertEqual(forward.branches.first?.segments.map(\.kind), [.cable])
        XCTAssertEqual(
            forward.branches.first?.segments.first?.workOrderRequest?.resourceKeys, [.object(cable.id), .object(cable.endpointA), .object(cable.endpointB)])
        XCTAssertEqual(reverse.branches.first?.nodes.map(\.id), [topology.panelPort.id, topology.switchPort.id])
        XCTAssertTrue(forward.isStale, "No successful server contact has been recorded for this mirror.")
    }

    private func assertAdapterNamespaceMismatch<T>(
        file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T
    ) async {
        let error = await assertThrowsAny(file: file, line: line, body)
        guard let error else { return }
        guard case ProductionAdapterError.namespaceMismatch = error else {
            return XCTFail("Expected namespaceMismatch, got \(error)", file: file, line: line)
        }
    }
}

struct AlwaysCurrentAuthorization: CurrentAuthorizationContextProviding {
    func validateCurrent(_: AuthorizedOperationContext) async -> Bool { true }
}

/// Seeds a foreign workspace first and then the adapter's own workspace into
/// the same store, so the adapter's namespace holds the active lease.
struct ReadFixture {
    let namespace: PersistenceNamespace
    let foreignNamespace: PersistenceNamespace
    let foreignDevice: Device
    let ipam: IPAMFixture
    let assignedAddress: IPAddressRecord
    let adapter: SwiftDataFeatureReadAdapter

    static func make(topology: TopologyFixture, hierarchy: HierarchyFixture) async throws -> ReadFixture {
        let store = try ServiceFixture.makeStore()
        let namespace = ServiceFixture.namespace()
        let foreignNamespace = ServiceFixture.namespace(owner: "other-owner")
        let foreignDevice = Device(assetCode: "SW-FOREIGN", name: "Switch foreign", typeID: topology.switchType.id)
        try await ServiceFixture.seed(
            store, namespace: foreignNamespace,
            records: try [
                ServiceFixture.mirror(topology.switchType, type: "NettworkDeviceType", namespace: foreignNamespace),
                ServiceFixture.mirror(foreignDevice, type: "NettworkDevice", namespace: foreignNamespace),
            ] + hierarchy.records(in: foreignNamespace))
        let ipam = IPAMFixture(deviceID: topology.switchDevice.id)
        var assigned = ipam.address
        assigned.assignedInterfaceID = ipam.interface.id
        let ipamRecords =
            try ipam.records(in: namespace).filter { $0.resourceKey != .string(assigned.id) } + [
                ServiceFixture.mirror(assigned, key: .string(assigned.id), type: "NettworkIPAddressRecord", namespace: namespace, tag: "assigned")
            ]
        try await ServiceFixture.seed(
            store, namespace: namespace,
            records: try topology.records(in: namespace, cables: [topology.patch()]) + hierarchy.records(in: namespace) + ipamRecords)
        let adapter = SwiftDataFeatureReadAdapter(
            account: ServiceFixture.account(namespace), persistence: store, reader: SwiftDataMirrorRecordEnumerator(persistence: store),
            currentAuthorizationContext: AlwaysCurrentAuthorization(), operationBoundary: try ServiceFixture.operationBoundary())
        return ReadFixture(
            namespace: namespace, foreignNamespace: foreignNamespace, foreignDevice: foreignDevice, ipam: ipam, assignedAddress: assigned,
            adapter: adapter)
    }
}
