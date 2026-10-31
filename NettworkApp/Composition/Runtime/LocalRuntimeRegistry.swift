import Foundation
import Persistence
import SwiftData
import WorkspaceServices

/// The process-wide objects of one local runtime root. Every scene assembly
/// over the same root shares them, so concurrent windows commit through one
/// record store actor and read one SwiftData container.
struct LocalRuntimeResources {
    let layout: LocalRuntimeLayout
    let identity: LocalWorkspaceIdentity
    let store: LocalWorkspaceRecordStore
    /// One draft store actor per root, so every scene sees the same drafts.
    let draftStore: FileBackedWorkOrderDraftStore
    let modelContainer: ModelContainer
    /// Stable for the identity; release scopes and actor contexts bind it.
    let installationID: String
    /// One installation session per process.
    let installationSession: LocalInstallationSession
}

/// Per-process cache of local runtime resources keyed by root directory.
@MainActor
enum LocalRuntimeRegistry {
    private static var resourcesByRoot: [URL: LocalRuntimeResources] = [:]

    /// Returns the cached resources for `layout`, or creates the layout, loads
    /// (or on first run creates) the identity and opens the on-disk mirror.
    /// A corrupt identity throws and nothing is cached.
    static func resources(for layout: LocalRuntimeLayout) throws -> LocalRuntimeResources {
        if let cached = resourcesByRoot[layout.root] { return cached }
        try layout.prepareRoot()
        let identity = try LocalWorkspaceIdentity.loadOrCreate(in: layout.identityDirectory)
        try layout.prepareWorkspace(identity.workspaceID)
        // The mirror must never attach to SwiftData's own CloudKit sync.
        let container = try NettworkPersistenceContainerFactory.make(
            configuration: ModelConfiguration(url: layout.mirrorStoreURL(for: identity.workspaceID), cloudKitDatabase: .none))
        let resources = LocalRuntimeResources(
            layout: layout,
            identity: identity,
            store: LocalWorkspaceRecordStore(directory: layout.serverDirectory(for: identity.workspaceID)),
            draftStore: FileBackedWorkOrderDraftStore(directory: layout.draftsDirectory(for: identity.workspaceID)),
            modelContainer: container,
            installationID: "local-installation-\(identity.workspaceID.description)",
            installationSession: LocalInstallationSession()
        )
        resourcesByRoot[layout.root] = resources
        return resources
    }
}
