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
        AppShell(router: launch.router)
            .environment(launch.dependencies.shell)
            .tint(.nettworkAccent)
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
            .onOpenURL { launch.router.handle(url: $0) }
    }
}
