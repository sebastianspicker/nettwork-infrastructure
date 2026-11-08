import FeatureContracts
import Foundation
import NetworkModel
import Observation
import SwiftUI
import WorkspaceChangeControl

enum ScanCaptureLifecycle: Equatable, Sendable {
    case inactive
    case requestingPermission
    case ready
    case suspended
    case cancelled
}

enum ScanResolutionState: Equatable, Sendable {
    case idle
    case resolving(ObjectID)
    case invalid(String)
    case unavailable(String)
    case resolved(ObjectID)
}

enum ScanDestination: Equatable, Sendable {
    case objectDetails(ObjectID)
}

/// Prevents simultaneous mirror reads while preserving the newest input as the
/// only completion allowed to update presentation state.
private actor ScanResolutionQueue {
    private var isOccupied = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard !isOccupied else {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        isOccupied = true
    }

    func release() {
        if waiters.isEmpty {
            isOccupied = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
@Observable
final class ScanIntakeModel {
    private let capture: any ScanCapturing
    private let resolver: any ScannedObjectResolving
    private let account: AccountContext
    private let resolutionQueue = ScanResolutionQueue()

    private(set) var captureAvailability: ScanCaptureAvailability = .checking
    private(set) var captureLifecycle: ScanCaptureLifecycle = .inactive
    private(set) var resolutionState: ScanResolutionState = .idle
    private(set) var destination: ScanDestination?
    var manualEntry = ""

    private var wedgeBuffer = ""
    private var shouldResumeCapture = false
    /// Bumped by cancel/suspend so a camera start that finishes afterwards is undone.
    private var captureGeneration = 0
    private var resolutionAttempt = 0

    init(
        account: AccountContext,
        capture: any ScanCapturing,
        resolver: any ScannedObjectResolving
    ) {
        self.account = account
        self.capture = capture
        self.resolver = resolver
    }

    func refreshCaptureAvailability() async {
        let availability = await capture.availability()
        guard captureLifecycle != .ready, captureLifecycle != .requestingPermission else { return }
        captureAvailability = availability
    }

    func begin() async {
        guard captureLifecycle == .inactive || captureLifecycle == .cancelled else { return }
        invalidateResolutionAttempts(resetState: true)
        destination = nil
        captureLifecycle = .requestingPermission
        captureAvailability = .checking
        captureGeneration &+= 1
        let generation = captureGeneration
        let availability = await capture.requestPermission()
        captureAvailability = availability
        guard generation == captureGeneration else { return }
        guard availability.canStart else {
            shouldResumeCapture = false
            captureLifecycle = .inactive
            return
        }
        await startCapture()
    }

    func suspend() async {
        guard captureLifecycle == .ready else { return }
        invalidateResolutionAttempts()
        shouldResumeCapture = true
        await capture.stop()
        captureLifecycle = .suspended
    }

    func resume() async {
        guard captureLifecycle == .suspended, shouldResumeCapture, captureAvailability.canStart else { return }
        await startCapture()
    }

    func cancel() async {
        captureGeneration &+= 1
        invalidateResolutionAttempts(resetState: true)
        shouldResumeCapture = false
        wedgeBuffer = ""
        await capture.stop()
        captureLifecycle = .cancelled
    }

    func updateScenePhase(_ phase: ScenePhase) async {
        switch phase {
        case .active:
            await resume()
        case .inactive:
            // Not an abort point: the camera permission prompt itself makes the scene inactive.
            await suspend()
        case .background:
            abortStartInProgress()
            await suspend()
        @unknown default:
            break
        }
    }

    /// A start still awaiting permission or the camera is dropped; the user starts again on return.
    private func abortStartInProgress() {
        guard captureLifecycle == .requestingPermission else { return }
        captureGeneration &+= 1
        shouldResumeCapture = false
        captureLifecycle = .inactive
    }

    func submitManual() async {
        let submission = manualEntry
        manualEntry = ""
        await accept(submission)
    }

    func receiveKeyboardWedge(_ text: String, isTerminator: Bool) async {
        wedgeBuffer.append(text)
        guard isTerminator else { return }
        defer { wedgeBuffer = "" }
        await accept(wedgeBuffer)
    }

    /// Camera delivery. The gate re-delivers a code in view every 2 s; the running lookup for it must finish.
    func acceptCameraCode(_ objectID: ObjectID) async {
        guard resolutionState != .resolving(objectID) else { return }
        await accept(ObjectLink.url(for: objectID).absoluteString)
    }

    func accept(_ rawValue: String) async {
        let attempt = nextResolutionAttempt()
        destination = nil
        guard let scan = OpaqueScanParser.parse(rawValue) else {
            resolutionState = .invalid("This is not a canonical opaque Nettwork object label.")
            return
        }

        resolutionState = .resolving(scan.objectID)
        await resolutionQueue.acquire()
        guard attempt == resolutionAttempt else {
            await resolutionQueue.release()
            return
        }

        let outcome: Result<Bool, Error>
        do {
            outcome = .success(try await resolver.resolve(scan.objectID, in: account.namespace))
        } catch {
            outcome = .failure(error)
        }
        await resolutionQueue.release()

        guard attempt == resolutionAttempt else { return }
        switch outcome {
        case .success(true):
            await stopCaptureAfterResolution(attempt: attempt)
            guard attempt == resolutionAttempt else { return }
            destination = .objectDetails(scan.objectID)
            resolutionState = .resolved(scan.objectID)
        case .success(false):
            resolutionState = .invalid("The label is valid but unavailable in this workspace or account.")
        case .failure:
            resolutionState = .unavailable("The scoped local mirror could not resolve this label.")
        }
    }

    private func startCapture() async {
        let generation = captureGeneration
        do {
            try await capture.start()
            guard generation == captureGeneration else {
                await capture.stop()
                return
            }
            shouldResumeCapture = true
            captureLifecycle = .ready
        } catch {
            guard generation == captureGeneration else { return }
            shouldResumeCapture = false
            captureLifecycle = .inactive
            captureAvailability = .unavailable(
                "Camera scanning is unavailable. Use typed, paste, or Bluetooth scanner input."
            )
        }
    }

    private func stopCaptureAfterResolution(attempt: Int) async {
        guard attempt == resolutionAttempt else { return }
        shouldResumeCapture = false
        let wasCapturing = captureLifecycle == .ready || captureLifecycle == .suspended
        captureLifecycle = .inactive
        if wasCapturing {
            await capture.stop()
        }
    }

    private func nextResolutionAttempt() -> Int {
        resolutionAttempt &+= 1
        return resolutionAttempt
    }

    private func invalidateResolutionAttempts(resetState: Bool = false) {
        _ = nextResolutionAttempt()
        if resetState {
            resolutionState = .idle
        }
    }
}
