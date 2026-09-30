import FeatureContracts
import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

@MainActor
final class OperationsScreenTests: XCTestCase {
    func testReportsAndAuditRefreshMaintainIndependentState() async {
        let service = OperationsReadModelStub()
        service.reportError = TestError.unavailable
        service.eventsByQuery[""] = [event(summary: "Accepted change")]
        let model = OperationsReadViewModel(service: service)

        await model.refreshAudit()
        await model.refreshReports()

        XCTAssertEqual(model.auditPhase, .loaded)
        XCTAssertEqual(model.auditEvents.map(\.summary), ["Accepted change"])
        XCTAssertEqual(model.reportsPhase, .failed("Unavailable"))
    }

    func testAuditRefreshIgnoresStaleCompletion() async {
        let service = OperationsReadModelStub()
        service.eventsByQuery["old"] = [event(summary: "Old")]
        service.eventsByQuery["new"] = [event(summary: "New")]
        service.delayByQuery["old"] = .milliseconds(150)
        let model = OperationsReadViewModel(service: service)
        model.auditQuery = "old"

        let oldRefresh = Task { await model.refreshAudit() }
        while service.requestedQueries.isEmpty { await Task.yield() }
        model.auditQuery = "new"
        await model.refreshAudit()
        await oldRefresh.value

        XCTAssertEqual(model.auditEvents.map(\.summary), ["New"])
        XCTAssertEqual(model.auditPhase, .loaded)
    }

    func testCancelledAuditRefreshDoesNotBecomeAnError() async {
        let service = OperationsReadModelStub()
        service.delayByQuery["slow"] = .seconds(5)
        let model = OperationsReadViewModel(service: service)
        model.auditQuery = "slow"

        let refresh = Task { await model.refreshAudit() }
        while service.requestedQueries.isEmpty { await Task.yield() }
        refresh.cancel()
        await refresh.value

        XCTAssertEqual(model.auditPhase, .idle)
        XCTAssertTrue(model.auditEvents.isEmpty)
    }

    func testEmptyModesAreExplicit() async {
        let model = OperationsReadViewModel(service: OperationsReadModelStub())

        await model.refreshReports()
        await model.refreshAudit()

        XCTAssertEqual(model.reportsPhase, .empty)
        XCTAssertEqual(model.auditPhase, .empty)
    }

    private func event(summary: String) -> AuditEventPresentation {
        AuditEventPresentation(
            event: AuditEvent(operationID: ObjectID(), actorID: "fixture", affectedObjectIDs: [], result: .accepted),
            summary: summary
        )
    }
}

@MainActor
private final class OperationsReadModelStub: OperationsReadModel {
    var eventsByQuery: [String: [AuditEventPresentation]] = [:]
    var delayByQuery: [String: Duration] = [:]
    var requestedQueries: [String] = []
    var reportError: Error?

    func auditEvents(matching query: String) async throws -> [AuditEventPresentation] {
        requestedQueries.append(query)
        if let delay = delayByQuery[query] { try await Task.sleep(for: delay) }
        return eventsByQuery[query, default: []]
    }

    func reports() async throws -> [OperationsReport] {
        if let reportError { throw reportError }
        return []
    }

    func syncHealth() async throws -> SyncHealthPresentation {
        SyncHealthPresentation(
            mirror: SyncMirrorPresentation(conflictCount: 0, lastSuccessfulServerContact: nil),
            queueDescription: "Empty",
            quarantineDescription: "Empty",
            backupDescription: "Not configured",
            accountFresh: true
        )
    }

    func workspaceAccess() async throws -> WorkspaceAccessPresentation {
        WorkspaceAccessPresentation(
            workspaceName: "Fixture workspace",
            accountRecordName: "fixture-account",
            role: .viewer,
            permission: .readOnly,
            policyVersion: "fixture-v1",
            disclosure: "Deterministic test fixture"
        )
    }

    func exportImmutableAudit(authorization _: AuthorizedOperationContext) async throws -> URL {
        URL(fileURLWithPath: "/tmp/fixture-audit.jsonl")
    }
}

private enum TestError: LocalizedError {
    case unavailable

    var errorDescription: String? { "Unavailable" }
}
