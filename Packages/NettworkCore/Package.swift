// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NettworkCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "NetworkModel", targets: ["NetworkModel"]),
        .library(name: "WorkspaceChangeControl", targets: ["WorkspaceChangeControl"]),
        .library(name: "Persistence", targets: ["Persistence"]),
        .library(name: "CloudSync", targets: ["CloudSync"]),
        .library(name: "ContentSafety", targets: ["ContentSafety"]),
        .library(name: "ImportExport", targets: ["ImportExport"]),
        .library(name: "FeatureContracts", targets: ["FeatureContracts"]),
        .library(name: "WorkspaceServices", targets: ["WorkspaceServices"]),
        .executable(name: "NettworkBenchmarks", targets: ["NettworkBenchmarks"]),
    ],
    targets: [
        .target(name: "NetworkModel"),
        .target(name: "WorkspaceChangeControl", dependencies: ["NetworkModel"]),
        .target(name: "Persistence", dependencies: ["NetworkModel", "WorkspaceChangeControl"]),
        .target(name: "CloudSync", dependencies: ["NetworkModel", "WorkspaceChangeControl", "Persistence"]),
        .target(name: "ContentSafety", dependencies: ["NetworkModel", "WorkspaceChangeControl"]),
        .target(name: "ImportExport", dependencies: ["NetworkModel", "WorkspaceChangeControl", "ContentSafety"]),
        .target(name: "FeatureContracts", dependencies: ["NetworkModel", "WorkspaceChangeControl", "ContentSafety", "ImportExport"]),
        .target(
            name: "WorkspaceServices",
            dependencies: [
                "NetworkModel", "WorkspaceChangeControl", "Persistence", "CloudSync", "ContentSafety", "ImportExport",
                "FeatureContracts",
            ]
        ),
        .executableTarget(name: "NettworkBenchmarks", dependencies: ["NetworkModel", "ImportExport"], path: "Benchmarks"),
        .testTarget(name: "NetworkModelTests", dependencies: ["NetworkModel"]),
        .testTarget(name: "WorkspaceChangeControlTests", dependencies: ["NetworkModel", "WorkspaceChangeControl"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence", "NetworkModel", "WorkspaceChangeControl"]),
        .testTarget(name: "CloudSyncTests", dependencies: ["CloudSync", "Persistence", "NetworkModel", "WorkspaceChangeControl"]),
        .testTarget(name: "ContentSafetyTests", dependencies: ["ContentSafety", "NetworkModel", "WorkspaceChangeControl"]),
        .testTarget(name: "ImportExportTests", dependencies: ["ImportExport", "ContentSafety", "NetworkModel", "WorkspaceChangeControl"]),
        .testTarget(name: "FeatureContractsTests", dependencies: ["FeatureContracts", "NetworkModel", "WorkspaceChangeControl"]),
        .testTarget(
            name: "WorkspaceServicesTests",
            dependencies: [
                "WorkspaceServices", "NetworkModel", "WorkspaceChangeControl", "Persistence", "CloudSync", "ContentSafety",
                "ImportExport", "FeatureContracts",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
