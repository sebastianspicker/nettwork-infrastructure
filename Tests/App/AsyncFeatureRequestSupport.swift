import Foundation
import NetworkModel
import WorkspaceChangeControl

@testable import Nettwork

/// Registers each request before releasing the test, without sleeps or polling.
actor ControlledFeatureRequest<Value: Sendable> {
    private var nextIndex = 0
    private var requests: [Int: CheckedContinuation<Value, any Error>] = [:]
    private var registrations: [Int: [CheckedContinuation<Void, Never>]] = [:]

    func perform() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            nextIndex += 1
            requests[nextIndex] = continuation
            for waiter in registrations.removeValue(forKey: nextIndex) ?? [] {
                waiter.resume()
            }
        }
    }

    func waitForRequest(_ index: Int) async {
        guard nextIndex < index else { return }
        await withCheckedContinuation { registrations[index, default: []].append($0) }
    }

    func succeed(_ index: Int, with value: Value) {
        requests.removeValue(forKey: index)?.resume(returning: value)
    }

    func fail(_ index: Int, with error: any Error = AsyncFeatureTestError.failed) {
        requests.removeValue(forKey: index)?.resume(throwing: error)
    }
}

enum AsyncFeatureTestError: Error { case failed }

func asyncFeatureTestAccount() -> AccountContext {
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
