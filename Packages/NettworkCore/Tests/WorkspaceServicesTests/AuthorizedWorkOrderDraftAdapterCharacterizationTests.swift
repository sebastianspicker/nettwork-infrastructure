import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import WorkspaceServices

/// Pins the draft adapter: requests outside the account namespace are
/// rejected before the authority is consulted, and a staged work order is
/// reported to the caller exactly once.
@MainActor
final class AuthorizedWorkOrderDraftAdapterCharacterizationTests: XCTestCase {
    private let topology = TopologyFixture()

    func testStagingDelegatesToTheAuthorityAndReportsTheStagedID() async throws {
        let account = ServiceFixture.account(ServiceFixture.namespace())
        let authority = RecordingMutationAuthority()
        let reported = StagedIDRecorder()
        let adapter = AuthorizedWorkOrderDraftAdapter(account: account, authority: authority) { reported.ids.append($0) }

        let topologyID = try await adapter.stage(topologyRequest(), in: account.namespace)
        let ipamID = try await adapter.stage(ipamRequest(), in: account.namespace)

        XCTAssertEqual([topologyID, ipamID], [authority.stagedID, authority.stagedID])
        XCTAssertEqual(reported.ids, [authority.stagedID, authority.stagedID])
        XCTAssertEqual(authority.calls.map(\.name), ["stageTopology", "stageIPAM"])
        XCTAssertEqual(Set(authority.calls.map(\.namespace)), [account.namespace])
    }

    func testStagingOutsideTheAccountNamespaceIsRejectedBeforeDelegation() async throws {
        let account = ServiceFixture.account(ServiceFixture.namespace())
        let authority = RecordingMutationAuthority()
        let reported = StagedIDRecorder()
        let adapter = AuthorizedWorkOrderDraftAdapter(account: account, authority: authority) { reported.ids.append($0) }
        let foreign = ServiceFixture.namespace(owner: "other-owner")

        let topologyError = await assertThrowsAny { try await adapter.stage(self.topologyRequest(), in: foreign) }
        let ipamError = await assertThrowsAny { try await adapter.stage(self.ipamRequest(), in: foreign) }
        for error in [topologyError, ipamError] {
            guard case ProductionAdapterError.namespaceMismatch? = error else {
                return XCTFail("Expected namespaceMismatch, got \(String(describing: error))")
            }
        }
        XCTAssertTrue(authority.calls.isEmpty)
        XCTAssertTrue(reported.ids.isEmpty)
    }

    private func topologyRequest() -> TopologyWorkOrderRequest {
        let cable = topology.patch()
        return TopologyWorkOrderRequest(
            title: "Patch", ticket: "CHG-1", notes: "", action: .connect(ConnectTopologyCommand(cable: cable)),
            resourceKeys: [.object(cable.id), .object(cable.endpointA), .object(cable.endpointB)])
    }

    private func ipamRequest() -> IPAMWorkOrderRequest {
        let ipam = IPAMFixture(deviceID: topology.switchDevice.id)
        return IPAMWorkOrderRequest(
            title: "Layout", ticketID: "CHG-2", notes: "", perVRFRevisionKey: .object(ipam.vrf.id),
            operation: .prefixLayout(PrefixLayoutWorkOrderRequest(vrf: ipam.vrf, currentPrefixes: [ipam.prefix], desiredPrefixes: [ipam.prefix])))
    }
}

@MainActor
final class StagedIDRecorder {
    var ids: [ObjectID] = []
}
