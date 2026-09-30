import FeatureContracts
import Foundation
import NetworkModel
import Persistence
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

/// Pins the corrective draft builder: a draft is built only from the typed
/// operator resolution bound to the exact, still-unresolved, non-security
/// reconciliation case, and never from reconciliation snapshot bytes.
final class ProductionCorrectiveDraftBuilderCharacterizationTests: XCTestCase {
    private let topology = TopologyFixture()

    func testDraftIsBuiltFromTheBoundOperatorResolution() async throws {
        let fixture = try await CorrectiveFixture.make(topology: topology)
        let command = DisconnectTopologyCommand(cableID: topology.patch().id, deletedAt: ServiceFixture.epoch)
        await fixture.provider.setOperation(.topology(.disconnect(command)))

        let draft = try await fixture.builder.correctiveDraft(for: fixture.reconciliation.id, actorID: "owner", in: fixture.namespace)

        XCTAssertEqual(draft.title, "Correct drift")
        XCTAssertEqual(draft.ticket, "INC-9")
        XCTAssertEqual(draft.kind, .disconnect)
        XCTAssertEqual(draft.operations, [.topology(.disconnect(command))])
        XCTAssertTrue(draft.resourceKeys.contains(.object(command.cableID)))
    }

    func testSecurityCasesAreNeverOfferedToTheResolutionProvider() async throws {
        let fixture = try await CorrectiveFixture.make(topology: topology, isSecurityEvent: true)

        await assertThrows(ProductionCorrectiveDraftBuilderError.securityCase) {
            try await fixture.builder.correctiveDraft(for: fixture.reconciliation.id, actorID: "owner", in: fixture.namespace)
        }
        let calls = await fixture.provider.callCount
        XCTAssertEqual(calls, 0)
    }

    func testUnknownCaseIsMissing() async throws {
        let fixture = try await CorrectiveFixture.make(topology: topology)

        await assertThrows(ProductionCorrectiveDraftBuilderError.reconciliationCaseMissing) {
            try await fixture.builder.correctiveDraft(for: ObjectID(), actorID: "owner", in: fixture.namespace)
        }
    }

    func testResolutionMustBindTheReviewedCaseAndActor() async throws {
        let fixture = try await CorrectiveFixture.make(topology: topology)
        await fixture.provider.setOperation(.topology(.disconnect(DisconnectTopologyCommand(cableID: topology.patch().id))))

        await fixture.provider.setDetectedAtOffset(1)
        await assertThrows(ProductionCorrectiveDraftBuilderError.staleResolution) {
            try await fixture.builder.correctiveDraft(for: fixture.reconciliation.id, actorID: "owner", in: fixture.namespace)
        }
        await fixture.provider.setDetectedAtOffset(0)
        await fixture.provider.setActorOverride("someone-else")
        await assertThrows(ProductionCorrectiveDraftBuilderError.staleResolution) {
            try await fixture.builder.correctiveDraft(for: fixture.reconciliation.id, actorID: "owner", in: fixture.namespace)
        }
    }

    func testDeviceRemovalAndBlankTicketsAreInvalidResolutions() async throws {
        let fixture = try await CorrectiveFixture.make(topology: topology)

        await fixture.provider.setOperation(.topology(.remove(RemoveTopologyCommand(deviceID: topology.panelDevice.id))))
        await assertThrows(ProductionCorrectiveDraftBuilderError.invalidResolution) {
            try await fixture.builder.correctiveDraft(for: fixture.reconciliation.id, actorID: "owner", in: fixture.namespace)
        }
        await fixture.provider.setOperation(.topology(.disconnect(DisconnectTopologyCommand(cableID: topology.patch().id))))
        await fixture.provider.setTicket("  ")
        await assertThrows(ProductionCorrectiveDraftBuilderError.invalidResolution) {
            try await fixture.builder.correctiveDraft(for: fixture.reconciliation.id, actorID: "owner", in: fixture.namespace)
        }
    }
}

/// Echoes the reviewed case back as a resolution, with individually
/// adjustable fields to model stale or invalid operator selections.
actor EchoResolutionProvider: CorrectiveResolutionProviding {
    private var operation = CorrectiveResolution.Operation.topology(.markUnavailable(.init(portID: ObjectID(), isUnavailable: true)))
    private var detectedAtOffset: TimeInterval = 0
    private var actorOverride: String?
    private var ticket = "INC-9"
    private(set) var callCount = 0

    func setOperation(_ operation: CorrectiveResolution.Operation) { self.operation = operation }
    func setDetectedAtOffset(_ offset: TimeInterval) { detectedAtOffset = offset }
    func setActorOverride(_ actorID: String?) { actorOverride = actorID }
    func setTicket(_ ticket: String) { self.ticket = ticket }

    func resolution(for reconciliationCase: ReconciliationCase, actorID: String, in namespace: PersistenceNamespace) async throws -> CorrectiveResolution {
        callCount += 1
        return CorrectiveResolution(
            reconciliationID: reconciliationCase.id, namespace: namespace, reconciliationOperationID: reconciliationCase.operationID,
            detectedAt: reconciliationCase.detectedAt.addingTimeInterval(detectedAtOffset), resourceKeys: reconciliationCase.resourceKeys,
            actorID: actorOverride ?? actorID, title: "Correct drift", ticket: ticket, notes: "", operation: operation)
    }
}

struct CorrectiveFixture {
    let namespace: PersistenceNamespace
    let reconciliation: ReconciliationCase
    let provider: EchoResolutionProvider
    let builder: ProductionCorrectiveDraftBuilder

    static func make(topology: TopologyFixture, isSecurityEvent: Bool = false) async throws -> CorrectiveFixture {
        let namespace = ServiceFixture.namespace()
        let store = try ServiceFixture.makeStore()
        _ = await store.activateLease(for: namespace)
        let reconciliation = ReconciliationCase(
            namespace: namespace, operationID: ObjectID(), resourceKeys: [.object(topology.patch().id)], reason: .serverRecordChanged, base: [:],
            intended: [:], current: [:], detectedAt: ServiceFixture.epoch, isSecurityEvent: isSecurityEvent)
        try await store.capture(reconciliation)
        let provider = EchoResolutionProvider()
        return CorrectiveFixture(
            namespace: namespace, reconciliation: reconciliation, provider: provider,
            builder: ProductionCorrectiveDraftBuilder(persistence: store, resolutionProvider: provider))
    }
}
