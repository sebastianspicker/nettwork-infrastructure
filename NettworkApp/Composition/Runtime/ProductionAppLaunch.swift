import Foundation
import OSLog
import Observation
import WorkspaceServices

/// Organization builds expose one NSObject-backed provider class through the
/// `NettworkProductionConfigurationProvider` Info.plist key. Keeping the input
/// construction outside this repository prevents placeholder identifiers,
/// policies, accounts, or filesystem destinations from becoming production
/// defaults while still giving the shipping app a reachable production path.
@MainActor
protocol ProductionRuntimeOrganizationInputProviding: AnyObject {
    init()
    func makeOrganizationInput() throws -> ProductionRuntimeAssembly.OrganizationInput
}

enum ProductionAppLaunchError: LocalizedError {
    case invalidProviderName
    case providerClassUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .invalidProviderName:
            "The production configuration provider name is invalid."
        case .providerClassUnavailable(let name):
            "The production configuration provider \(name) could not be loaded."
        }
    }
}

@MainActor
enum ProductionAppLaunchConfiguration {
    static let providerInfoKey = "NettworkProductionConfigurationProvider"

    /// Parses the organization-controlled Info.plist value. Missing or empty
    /// values (the checked-in default) keep the application unconfigured;
    /// malformed values are launch failures.
    static func providerName(from infoValue: Any?) throws -> String? {
        guard let infoValue else {
            return nil
        }
        guard let name = infoValue as? String else {
            throw ProductionAppLaunchError.invalidProviderName
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name
    }

    /// Resolves only NSObject-backed organization provider types. The injected
    /// lookup keeps validation testable without a production assembly.
    static func providerType(
        named name: String,
        classLookup: (String) -> AnyClass? = NSClassFromString
    ) throws -> ProductionRuntimeOrganizationInputProviding.Type {
        guard let providerClass = classLookup(name),
            providerClass is NSObject.Type,
            let providerType = providerClass as? ProductionRuntimeOrganizationInputProviding.Type
        else {
            throw ProductionAppLaunchError.providerClassUnavailable(name)
        }
        return providerType
    }

    static func provider(
        from infoValue: Any?,
        classLookup: (String) -> AnyClass? = NSClassFromString
    ) throws -> (any ProductionRuntimeOrganizationInputProviding)? {
        guard let name = try providerName(from: infoValue) else {
            return nil
        }
        return try providerType(named: name, classLookup: classLookup).init()
    }

    static func provider(in bundle: Bundle = .main) throws -> (any ProductionRuntimeOrganizationInputProviding)? {
        try provider(from: bundle.object(forInfoDictionaryKey: providerInfoKey))
    }
}

/// Owns the retained production assembly for the whole SwiftUI scene lifetime.
/// An absent provider stays visibly fail-closed; a configured but invalid
/// provider reports its exact launch error instead of silently falling back.
///
/// Start, stop, and account-change restarts run strictly one after another.
/// A CloudKit account change closes the account-scoped graph and builds a fresh
/// assembly from the organization provider, so a different account never
/// reuses the previous account's mirror; activation re-verifies the account.
@MainActor
@Observable
final class ProductionAppLaunchController {
    /// Minimum spacing between automatic foreground syncs on scene activation.
    static let foregroundSyncInterval: TimeInterval = 30

    private(set) var dependencies: AppDependencies
    private(set) var router: AppRouter
    private let explicitComposition: AppRuntimeComposition?
    private let accountChanges: ProductionCloudAccountChangeObserver
    private var assembly: ProductionRuntimeAssembly?
    private var hasStarted = false
    /// A link that arrives while the runtime is still being assembled waits here, so the
    /// placeholder shell (which may consume links) never sees it; delivered once the real router exists.
    private var isAwaitingRuntime = true
    private var pendingLink: URL?
    /// Startup failures are otherwise visible only as on-screen status text;
    /// the privacy-safe label lets bug reports name the failing step.
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nettwork", category: "launch")
    private var platformCapabilities: ProductionRuntimeAssembly.OrganizationInput.PlatformCapabilities?
    private var lifecycleQueue: Task<Void, Never>?
    private var lifecycleOperationCount = 0
    private var isAccountChangeQueued = false
    private var lastForegroundSync: Date?

    init(composition: AppRuntimeComposition? = nil, accountChanges: ProductionCloudAccountChangeObserver = ProductionCloudAccountChangeObserver()) {
        explicitComposition = composition
        self.accountChanges = accountChanges
        let initial = composition ?? .unconfigured
        dependencies = initial.dependencies
        router = initial.router
    }

    func start(
        systemPlatformCapabilities: ProductionRuntimeAssembly.OrganizationInput.PlatformCapabilities
    ) async {
        await serialized { await self.performStart(systemPlatformCapabilities) }
    }

    func stop() async {
        await serialized { await self.performStop() }
    }

    /// Invalidates the current session and re-runs activation. Repeated
    /// notifications while a restart is queued coalesce into that restart.
    func handleCloudAccountChange() async {
        guard !isAccountChangeQueued else { return }
        isAccountChangeQueued = true
        await serialized {
            self.isAccountChangeQueued = false
            guard self.hasStarted, let capabilities = self.platformCapabilities else { return }
            await self.performStop()
            await self.performStart(capabilities)
        }
    }

    /// Runs a foreground sync when the scene becomes active, unless the app is
    /// not running, a start/stop/restart is in progress, or one ran recently.
    func sceneDidBecomeActive(now: Date = .now) async {
        guard hasStarted, lifecycleOperationCount == 0 else { return }
        if let lastForegroundSync, now.timeIntervalSince(lastForegroundSync) < Self.foregroundSyncInterval { return }
        lastForegroundSync = now
        await dependencies.synchronizeForeground()
    }

    private func serialized(_ operation: @escaping @MainActor @Sendable () async -> Void) async {
        let previous = lifecycleQueue
        let current = Task { @MainActor in
            await previous?.value
            await operation()
        }
        lifecycleQueue = current
        lifecycleOperationCount += 1
        await current.value
        lifecycleOperationCount -= 1
    }

    private func performStart(_ systemPlatformCapabilities: ProductionRuntimeAssembly.OrganizationInput.PlatformCapabilities) async {
        guard !hasStarted else { return }
        hasStarted = true
        isAwaitingRuntime = true
        platformCapabilities = systemPlatformCapabilities
        do {
            if explicitComposition == nil,
                let provider = try ProductionAppLaunchConfiguration.provider()
            {
                let input = try provider.makeOrganizationInput()
                observeAccountChanges(for: input.cloudWorkspace.backend.kind)
                let production = try await ProductionRuntimeAssembly.make(
                    organization: input,
                    systemPlatformCapabilities: systemPlatformCapabilities
                )
                assembly = production
                dependencies = production.composition.dependencies
                router = production.composition.router
            }
            deliverPendingLink()
            await dependencies.bootstrap()
        } catch {
            Self.logger.error("startup failed: \(PrivacySafeErrorDiagnostics.label(for: error), privacy: .public)")
            let failed = AppRuntimeComposition(
                dependencies: AppDependencies(
                    bootstrapService: UnconfiguredAppBootstrapService(
                        message: "Production workspace startup failed: \(error.localizedDescription)"
                    )
                ),
                router: AppRouter()
            )
            assembly = nil
            dependencies = failed.dependencies
            router = failed.router
            deliverPendingLink()
            await dependencies.bootstrap()
        }
        lastForegroundSync = .now
    }

    /// Routes an incoming `nettwork://` link; while the runtime is assembling it is held back.
    func open(_ url: URL) {
        guard !isAwaitingRuntime else {
            pendingLink = url
            return
        }
        router.handle(url: url)
    }

    private func deliverPendingLink() {
        isAwaitingRuntime = false
        if let pendingLink { router.handle(url: pendingLink) }
        pendingLink = nil
    }

    private func performStop() async {
        // Links arriving during shutdown wait for the next runtime's router.
        isAwaitingRuntime = true
        accountChanges.stop()
        await dependencies.shutdown()
        assembly = nil
        hasStarted = false
    }

    /// Only the CloudKit backend has an iCloud account to follow. The observer
    /// stays installed after a failed assembly so switching accounts can recover.
    private func observeAccountChanges(for backend: ProductionRuntimeAssembly.OrganizationInput.CloudWorkspace.BackendKind) {
        guard backend == .cloudKit else { return }
        accountChanges.start { [weak self] in
            Task { await self?.handleCloudAccountChange() }
        }
    }
}
