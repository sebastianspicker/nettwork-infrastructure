import WorkspaceChangeControl

@MainActor
struct AppRuntimeComposition {
    let dependencies: AppDependencies
    let router: AppRouter

    static var unconfigured: AppRuntimeComposition {
        AppRuntimeComposition(dependencies: AppDependencies(), router: AppRouter())
    }

    static func production(
        features: AppFeatureComposition,
        activateWorkspace: @escaping () async throws -> Void,
        syncCoordinator: any SyncCoordinator,
        invalidateWorkspace: @escaping () async -> Void,
        hasActiveWorkspaceSession: @escaping () async -> Bool
    ) -> AppRuntimeComposition {
        let bootstrap = ProductionAppBootstrapService(
            activateWorkspace: activateWorkspace,
            syncCoordinator: syncCoordinator,
            invalidateWorkspace: invalidateWorkspace,
            hasActiveWorkspaceSession: hasActiveWorkspaceSession
        )
        return AppRuntimeComposition(
            dependencies: AppDependencies(
                features: .configured(features),
                bootstrapService: bootstrap
            ),
            router: AppRouter()
        )
    }
}
