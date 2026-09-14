import Foundation
import NetworkModel
import WorkspaceChangeControl
import XCTest

@testable import Nettwork

final class ScanIntakeFeatureTests: XCTestCase {
    @MainActor
    func testResolvedCameraLabelStopsCaptureAndKeepsResolutionSeparate() async {
        let objectID = ObjectID()
        let capture = ScanCaptureProbe(availability: .available)
        let model = ScanIntakeModel(
            account: scanTestAccount(),
            capture: capture,
            resolver: ScanResolverStub(results: [objectID: true])
        )

        await model.begin()
        XCTAssertEqual(model.captureLifecycle, .ready)
        XCTAssertEqual(model.resolutionState, .idle)

        await model.accept(ObjectLink.url(for: objectID).absoluteString)

        XCTAssertEqual(model.captureLifecycle, .inactive)
        XCTAssertEqual(model.resolutionState, .resolved(objectID))
        XCTAssertEqual(model.destination, .objectDetails(objectID))
        let stops = await capture.stopCount()
        XCTAssertEqual(stops, 1)
    }

    @MainActor
    func testManualResolutionRemainsAvailableWhenCameraIsUnauthorized() async {
        let objectID = ObjectID()
        let reason = "Camera access is not authorized."
        let capture = ScanCaptureProbe(availability: .unauthorized(reason))
        let model = ScanIntakeModel(
            account: scanTestAccount(),
            capture: capture,
            resolver: ScanResolverStub(results: [objectID: true])
        )

        await model.refreshCaptureAvailability()
        XCTAssertEqual(model.captureAvailability, .unauthorized(reason))

        model.manualEntry = ObjectLink.url(for: objectID).absoluteString
        await model.submitManual()

        XCTAssertEqual(model.resolutionState, .resolved(objectID))
        XCTAssertEqual(model.destination, .objectDetails(objectID))
        let starts = await capture.startCount()
        XCTAssertEqual(starts, 0)
    }

    @MainActor
    func testResolutionQueueIgnoresStaleCompletionAndOnlyStartsOneReadAtATime() async {
        let firstID = ObjectID()
        let secondID = ObjectID()
        let resolver = ControlledScanResolver()
        let model = ScanIntakeModel(
            account: scanTestAccount(),
            capture: ScanCaptureProbe(availability: .unavailable("No camera")),
            resolver: resolver
        )

        let first = Task { await model.accept(ObjectLink.url(for: firstID).absoluteString) }
        await waitUntil { await resolver.requestedIDs() == [firstID] }

        let second = Task { await model.accept(ObjectLink.url(for: secondID).absoluteString) }
        for _ in 0..<10 { await Task.yield() }
        let requestsBeforeFirstCompletion = await resolver.requestedIDs()
        XCTAssertEqual(requestsBeforeFirstCompletion, [firstID])

        await resolver.resume(firstID, with: .success(true))
        await waitUntil { await resolver.requestedIDs() == [firstID, secondID] }
        await resolver.resume(secondID, with: .success(true))
        _ = await first.value
        _ = await second.value

        XCTAssertEqual(model.resolutionState, .resolved(secondID))
        XCTAssertEqual(model.destination, .objectDetails(secondID))
    }

    @MainActor
    func testBackgroundSuspendsAndActiveSceneResumesCapture() async {
        let capture = ScanCaptureProbe(availability: .available)
        let model = ScanIntakeModel(
            account: scanTestAccount(),
            capture: capture,
            resolver: ScanResolverStub(results: [:])
        )

        await model.begin()
        await model.updateScenePhase(.background)
        XCTAssertEqual(model.captureLifecycle, .suspended)
        let stops = await capture.stopCount()
        XCTAssertEqual(stops, 1)

        await model.updateScenePhase(.active)
        XCTAssertEqual(model.captureLifecycle, .ready)
        let starts = await capture.startCount()
        XCTAssertEqual(starts, 2)
    }

    @MainActor
    func testCaptureFailureKeepsManualResolutionAvailable() async {
        let objectID = ObjectID()
        let capture = ScanCaptureProbe(availability: .available, failStart: true)
        let model = ScanIntakeModel(
            account: scanTestAccount(),
            capture: capture,
            resolver: ScanResolverStub(results: [objectID: true])
        )

        await model.begin()
        XCTAssertEqual(model.captureLifecycle, .inactive)
        XCTAssertFalse(model.captureAvailability.canStart)

        model.manualEntry = ObjectLink.url(for: objectID).absoluteString
        await model.submitManual()
        XCTAssertEqual(model.destination, .objectDetails(objectID))
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("The controlled scan resolution was not registered.", file: file, line: line)
    }
}

private func scanTestAccount() -> AccountContext {
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

private actor ScanCaptureProbe: ScanCapturing {
    private let configuredAvailability: ScanCaptureAvailability
    private let failStart: Bool
    private var starts = 0
    private var stops = 0

    init(availability: ScanCaptureAvailability, failStart: Bool = false) {
        configuredAvailability = availability
        self.failStart = failStart
    }

    func availability() async -> ScanCaptureAvailability { configuredAvailability }
    func requestPermission() async -> ScanCaptureAvailability { configuredAvailability }
    func start() async throws {
        starts += 1
        if failStart { throw ScanCaptureProbeError.failed }
    }
    func stop() async { stops += 1 }
    func startCount() -> Int { starts }
    func stopCount() -> Int { stops }
}

private enum ScanCaptureProbeError: Error {
    case failed
}

private actor ScanResolverStub: ScannedObjectResolving {
    private let results: [ObjectID: Bool]

    init(results: [ObjectID: Bool]) {
        self.results = results
    }

    func resolve(_ id: ObjectID, in _: PersistenceNamespace) async throws -> Bool {
        results[id, default: false]
    }
}

private actor ControlledScanResolver: ScannedObjectResolving {
    private var requested: [ObjectID] = []
    private var continuations: [ObjectID: CheckedContinuation<Result<Bool, Error>, Never>] = [:]

    func resolve(_ id: ObjectID, in _: PersistenceNamespace) async throws -> Bool {
        let result = await withCheckedContinuation { continuation in
            requested.append(id)
            continuations[id] = continuation
        }
        return try result.get()
    }

    func requestedIDs() -> [ObjectID] { requested }

    func resume(_ id: ObjectID, with result: Result<Bool, Error>) {
        continuations.removeValue(forKey: id)?.resume(returning: result)
    }
}
