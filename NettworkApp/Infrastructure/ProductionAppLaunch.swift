import Foundation
import Observation

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

    /// Parses the organization-controlled Info.plist value. Missing values keep
    /// the application unconfigured; malformed values are launch failures.
    static func providerName(from infoValue: Any?) throws -> String? {
        guard let infoValue else {
            return nil
        }
        guard let name = infoValue as? String,
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ProductionAppLaunchError.invalidProviderName
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
@MainActor
@Observable
final class ProductionAppLaunchController {
    private(set) var dependencies: AppDependencies
    private(set) var router: AppRouter
    private let explicitComposition: AppRuntimeComposition?
    private var assembly: ProductionRuntimeAssembly?
    private var hasStarted = false

    init(composition: AppRuntimeComposition? = nil) {
        explicitComposition = composition
        let initial = composition ?? .unconfigured
        dependencies = initial.dependencies
        router = initial.router
    }

    func start(
        systemPlatformCapabilities: ProductionRuntimeAssembly.OrganizationInput.PlatformCapabilities
    ) async {
        guard !hasStarted else { return }
        hasStarted = true
        do {
            if explicitComposition == nil,
                let provider = try ProductionAppLaunchConfiguration.provider()
            {
                let production = try await ProductionRuntimeAssembly.make(
                    organization: provider.makeOrganizationInput(),
                    systemPlatformCapabilities: systemPlatformCapabilities
                )
                assembly = production
                dependencies = production.composition.dependencies
                router = production.composition.router
            }
            await dependencies.bootstrap()
        } catch {
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
            await dependencies.bootstrap()
        }
    }

    func stop() async {
        await dependencies.shutdown()
        assembly = nil
        hasStarted = false
    }
}
