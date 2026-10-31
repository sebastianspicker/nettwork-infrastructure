import Foundation
import WorkspaceChangeControl

/// Installation session identifier that is stable for the lifetime of the
/// value (create one per process) and changes on every launch.
public struct LocalInstallationSession: ProductionInstallationSessionProviding {
    public let id: String

    public init(id: String = UUID().uuidString.lowercased()) { self.id = id }

    public func sessionID(for _: ActorContext, account _: AccountContext) async throws -> String {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalWorkspaceAuthorityError.invalidInstallationSession }
        return id
    }
}
