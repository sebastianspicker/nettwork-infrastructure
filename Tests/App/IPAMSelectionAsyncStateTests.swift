import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

@MainActor
final class IPAMSelectionAsyncStateTests: XCTestCase {
    func testLatestPrefixRetainsItsAddressesWhenOldSelectionFinishesLast() async throws {
        let browser = try ControlledIPAMBrowser()
        let model = makeModel(browser)
        await model.load()
        let first = Task { await model.selectPrefix(browser.prefixValues[0].id) }
        await browser.addressRequests.waitForRequest(1)
        let second = Task { await model.selectPrefix(browser.prefixValues[1].id) }
        await browser.addressRequests.waitForRequest(2)
        let newest = address("10.2.0.1")
        await browser.addressRequests.succeed(2, with: [newest])
        await second.value
        await browser.addressRequests.succeed(1, with: [address("10.1.0.1")])
        await first.value

        XCTAssertEqual(model.selectedPrefixID, browser.prefixValues[1].id)
        XCTAssertEqual(model.addresses, [newest])
    }

    func testChangingSelectionClearsAlreadyLoadedAddressesImmediately() async throws {
        let browser = try ControlledIPAMBrowser()
        let model = makeModel(browser)
        await model.load()
        let first = Task { await model.selectPrefix(browser.prefixValues[0].id) }
        await browser.addressRequests.waitForRequest(1)
        await browser.addressRequests.succeed(1, with: [address("10.1.0.1")])
        await first.value
        let second = Task { await model.selectPrefix(browser.prefixValues[1].id) }
        await browser.addressRequests.waitForRequest(2)
        XCTAssertTrue(model.addresses.isEmpty)
        await browser.addressRequests.succeed(2, with: [])
        await second.value
    }

    func testVRFNewPrefixAndReloadInvalidatePendingAddressResults() async throws {
        for transition in 0..<3 {
            let browser = try ControlledIPAMBrowser()
            let model = makeModel(browser)
            await model.load()
            let selection = Task { await model.selectPrefix(browser.prefixValues[0].id) }
            await browser.addressRequests.waitForRequest(1)
            switch transition {
            case 0: model.selectVRF(browser.vrfValues[1].id)
            case 1: model.beginNewPrefix()
            default:
                model.selectVRF(browser.vrfValues[1].id)
                await model.load()
            }
            await browser.addressRequests.succeed(1, with: [address("10.1.0.1")])
            await selection.value
            XCTAssertTrue(model.addresses.isEmpty)
            XCTAssertEqual(model.state, .ready)
        }
    }

    func testStaleFailureCannotReplaceNewPrefixState() async throws {
        let browser = try ControlledIPAMBrowser()
        let model = makeModel(browser)
        await model.load()
        let first = Task { await model.selectPrefix(browser.prefixValues[0].id) }
        await browser.addressRequests.waitForRequest(1)
        let second = Task { await model.selectPrefix(browser.prefixValues[1].id) }
        await browser.addressRequests.waitForRequest(2)
        await browser.addressRequests.succeed(2, with: [])
        await second.value
        await browser.addressRequests.fail(1)
        await first.value
        XCTAssertEqual(model.state, .ready)
    }

    func testCancelledRequestDiscardsSuccessAndCancellationError() async throws {
        for fails in [false, true] {
            let browser = try ControlledIPAMBrowser()
            let model = makeModel(browser)
            await model.load()
            let selection = Task { await model.selectPrefix(browser.prefixValues[0].id) }
            await browser.addressRequests.waitForRequest(1)
            selection.cancel()
            if fails {
                await browser.addressRequests.fail(1, with: CancellationError())
            } else {
                await browser.addressRequests.succeed(1, with: [address("10.1.0.1")])
            }
            await selection.value
            XCTAssertTrue(model.addresses.isEmpty)
            XCTAssertEqual(model.state, .ready)
        }
    }

    func testReloadRestoresSelectedPrefixAddressesAndPreservesUnsavedEditor() async throws {
        let browser = try ControlledIPAMBrowser(controlledCatalog: true)
        let model = await loadedSelectedPrefix(browser)
        model.prefixCIDR = "10.1.0.0/24"
        model.prefixName = "Unsaved edit"
        model.reservedRanges = "10.1.0.10-10.1.0.20"
        let reload = Task { await model.load() }
        await browser.prefixRequests.waitForRequest(2)
        XCTAssertTrue(model.addresses.isEmpty)
        await browser.prefixRequests.succeed(2, with: browser.prefixValues)
        await browser.addressRequests.waitForRequest(2)
        let refreshed = address("10.1.0.2")
        await browser.addressRequests.succeed(2, with: [refreshed])
        let loaded = await reload.value
        XCTAssertTrue(loaded)
        XCTAssertEqual(model.selectedPrefixID, browser.prefixValues[0].id)
        XCTAssertEqual(model.prefixCIDR, "10.1.0.0/24")
        XCTAssertEqual(model.prefixName, "Unsaved edit")
        XCTAssertEqual(model.reservedRanges, "10.1.0.10-10.1.0.20")
        XCTAssertEqual(model.addresses, [refreshed])
    }

    func testSelectionStartedDuringReloadCannotPublishForRemovedPrefix() async throws {
        let browser = try ControlledIPAMBrowser(controlledCatalog: true)
        let model = makeModel(browser)
        await loadCatalog(model, browser: browser, index: 1, prefixes: browser.prefixValues)
        let reload = Task { await model.load() }
        await browser.prefixRequests.waitForRequest(2)
        let selection = Task { await model.selectPrefix(browser.prefixValues[0].id) }
        await browser.addressRequests.waitForRequest(1)
        await browser.prefixRequests.succeed(2, with: [browser.prefixValues[1]])
        _ = await reload.value
        await browser.addressRequests.succeed(1, with: [address("10.1.0.1")])
        await selection.value
        XCTAssertNil(model.selectedPrefixID)
        XCTAssertNil(model.prefixEditorID)
        XCTAssertTrue(model.addresses.isEmpty)
        XCTAssertEqual(model.state, .ready)
    }

    func testSelectionChangedDuringReloadRemainsCurrent() async throws {
        let browser = try ControlledIPAMBrowser(controlledCatalog: true)
        let model = await loadedSelectedPrefix(browser)
        let reload = Task { await model.load() }
        await browser.prefixRequests.waitForRequest(2)
        model.selectVRF(browser.vrfValues[1].id)
        await browser.prefixRequests.succeed(2, with: browser.prefixValues)
        _ = await reload.value
        XCTAssertEqual(model.selectedVRFID, browser.vrfValues[1].id)
        XCTAssertNil(model.selectedPrefixID)
        XCTAssertTrue(model.addresses.isEmpty)
    }

    private func loadedSelectedPrefix(_ browser: ControlledIPAMBrowser) async -> IPAMWorkspaceModel {
        let model = makeModel(browser)
        await loadCatalog(model, browser: browser, index: 1, prefixes: browser.prefixValues)
        let selection = Task { await model.selectPrefix(browser.prefixValues[0].id) }
        await browser.addressRequests.waitForRequest(1)
        await browser.addressRequests.succeed(1, with: [address("10.1.0.1")])
        await selection.value
        return model
    }

    private func loadCatalog(
        _ model: IPAMWorkspaceModel, browser: ControlledIPAMBrowser, index: Int, prefixes: [IPAMPrefixSnapshot]
    ) async {
        let loading = Task { await model.load() }
        await browser.prefixRequests.waitForRequest(index)
        await browser.prefixRequests.succeed(index, with: prefixes)
        _ = await loading.value
    }

    private func makeModel(_ browser: ControlledIPAMBrowser) -> IPAMWorkspaceModel {
        IPAMWorkspaceModel(account: asyncFeatureTestAccount(), browser: browser, drafts: AsyncIPAMDraftStub())
    }

    private func address(_ value: String) -> IPAMAddressSnapshot {
        IPAMAddressSnapshot(
            id: ObjectID(), resourceKey: .string(value), address: value, interfaceName: nil,
            vlanName: nil, assignments: [], state: .active, isPlanned: false, isPending: false, isConflicted: false
        )
    }
}

private struct ControlledIPAMBrowser: IPAMBrowsing {
    let addressRequests = ControlledFeatureRequest<[IPAMAddressSnapshot]>()
    let prefixRequests = ControlledFeatureRequest<[IPAMPrefixSnapshot]>()
    private let controlledCatalog: Bool
    let vrfValues: [VRFSnapshot]
    let prefixValues: [IPAMPrefixSnapshot]

    init(controlledCatalog: Bool = false) throws {
        self.controlledCatalog = controlledCatalog
        let vrfs = [VRF(name: "First"), VRF(name: "Second")]
        vrfValues = vrfs.map {
            VRFSnapshot(
                value: $0, id: $0.id, name: $0.name, revision: $0.revision,
                state: .active, isPlanned: false, isPending: false, isConflicted: false)
        }
        prefixValues = try vrfs.enumerated().map { index, vrf in
            let prefix = try XCTUnwrap(Prefix(vrfID: vrf.id, cidr: "10.\(index + 1).0.0/16", name: vrf.name))
            return IPAMPrefixSnapshot(
                value: prefix, id: prefix.id, vrfID: vrf.id, cidr: prefix.cidr, name: prefix.name,
                utilization: 0, state: .active, reservedSummary: "0 reserved ranges",
                isPlanned: false, isPending: false, isConflicted: false
            )
        }
    }

    func vrfs(in namespace: PersistenceNamespace) async throws -> [VRFSnapshot] { vrfValues }
    func prefixes(in namespace: PersistenceNamespace) async throws -> [IPAMPrefixSnapshot] {
        if controlledCatalog { return try await prefixRequests.perform() }
        return prefixValues
    }
    func addresses(prefixID: ObjectID, in namespace: PersistenceNamespace) async throws -> [IPAMAddressSnapshot] {
        try await addressRequests.perform()
    }
    func vlans(in namespace: PersistenceNamespace) async throws -> [VLANSnapshot] { [] }
    func interfaces(in namespace: PersistenceNamespace) async throws -> [LogicalInterfaceSnapshot] { [] }
}

private struct AsyncIPAMDraftStub: IPAMWorkOrderDrafting {
    func stage(_ request: IPAMWorkOrderRequest, in namespace: PersistenceNamespace) async throws -> ObjectID { ObjectID() }
}
