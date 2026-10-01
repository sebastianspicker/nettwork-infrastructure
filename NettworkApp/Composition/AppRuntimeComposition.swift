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
        invalidateWorkspace: @escaping () async -> Void
    ) -> AppRuntimeComposition {
        let bootstrap = ProductionAppBootstrapService(
            activateWorkspace: activateWorkspace,
            syncCoordinator: syncCoordinator,
            invalidateWorkspace: invalidateWorkspace
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
