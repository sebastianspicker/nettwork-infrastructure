import SwiftUI

@main
struct NettworkApp: App {
    private let composition: AppRuntimeComposition?

    @MainActor
    init() {
        composition = nil
    }

    @MainActor
    init(composition: AppRuntimeComposition?) {
        self.composition = composition
    }

    var body: some Scene {
        WindowGroup {
            NettworkSceneRoot(composition: composition)
        }
        #if os(macOS)
            .defaultSize(width: 1240, height: 820)
        #endif
    }
}

private struct NettworkSceneRoot: View {
    @State private var launch: ProductionAppLaunchController
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
        @State private var presentationContext = IOSPresentationContext()
    #endif

    @MainActor
    init(composition: AppRuntimeComposition?) {
        _launch = State(initialValue: ProductionAppLaunchController(composition: composition))
    }

    var body: some View {
        productionRoot
    }

    private var productionRoot: some View {
        // The lifecycle modifiers sit on a container with a stable identity: if they shared the
        // shell's `.id`, every runtime swap would re-fire `onDisappear` (stop) and `.task` (start).
        ZStack {
            AppShell(router: launch.router)
                // A new runtime (account switch) must not keep screens bound to the old account's models.
                .id(ObjectIdentifier(launch.dependencies))
                .environment(launch.dependencies.shell)
                .tint(.nettworkAccent)
        }
        #if os(iOS)
            .background(IOSPresentationContextAnchor(context: presentationContext).frame(width: 0, height: 0))
        #endif
        .task {
            #if os(iOS)
                await launch.start(systemPlatformCapabilities: .system(presentationContext: presentationContext))
            #else
                await launch.start(systemPlatformCapabilities: .system())
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await launch.sceneDidBecomeActive() }
        }
        .onDisappear {
            Task { await launch.stop() }
        }
        .onOpenURL { launch.open($0) }
    }
}
