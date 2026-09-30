import Foundation
import NetworkModel
import WorkspaceChangeControl

/// Camera availability is independent from the current capture lifecycle so
/// typed, pasted, and keyboard-wedge scans stay usable on every platform.
public enum ScanCaptureAvailability: Equatable, Sendable {
    case checking
    case available
    case unauthorized(String)
    case unavailable(String)

    public var reason: String? {
        switch self {
        case .checking, .available:
            nil
        case .unauthorized(let reason), .unavailable(let reason):
            reason
        }
    }

    public var canStart: Bool {
        if case .available = self { return true }
        return false
    }
}

public struct OpaqueScan: Equatable, Sendable {
    public let objectID: ObjectID

    public init(objectID: ObjectID) {
        self.objectID = objectID
    }
}

public enum OpaqueScanParser {
    public static func parse(_ rawValue: String) -> OpaqueScan? {
        guard let id = ObjectLink.objectID(from: rawValue) else { return nil }
        return OpaqueScan(objectID: id)
    }
}

public protocol ScanCapturing: Sendable {
    func availability() async -> ScanCaptureAvailability
    func requestPermission() async -> ScanCaptureAvailability
    func start() async throws
    func stop() async
}

public protocol ScannedObjectResolving: Sendable {
    func resolve(_ id: ObjectID, in namespace: PersistenceNamespace) async throws -> Bool
}
