// swift-tools-version: 5.10
import PackageDescription

/// Linux/macOS CI package for OffloadPro's pure service-layer logic.
/// The shipping iOS app is still generated via `project.yml` + XcodeGen;
/// this package excludes PhotoKit/UIKit/RevenueCat/Sentry UI surfaces so
/// the golden-rule unit suite can run without Xcode.
let package = Package(
    name: "OffloadPro",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "OffloadPro", targets: ["OffloadPro"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.8.0"),
    ],
    targets: [
        .target(
            name: "OffloadPro",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "OffloadPro",
            exclude: [
                "App",
                "Features",
                "Resources",
                "Services/Destinations",
                "Services/Purchases",
                "Services/Offload/AssetExportService.swift",
                "Services/Offload/OffloadCoordinator.swift",
                "Services/Scanner/PhotoAuthService.swift",
                "Services/Scanner/PhotoKitAssetProvider.swift",
                "Services/Pendrive/PendriveService.swift",
                "Services/Smart/BeforeTripScheduler.swift",
            ],
            sources: [
                "Core",
                "Services/Scanner/AssetProviding.swift",
                "Services/Scanner/AssetSizer.swift",
                "Services/Scanner/AssetClassifier.swift",
                "Services/Scanner/DHash.swift",
                "Services/Scanner/BlurScorer.swift",
                "Services/Scanner/DuplicateDetector.swift",
                "Services/Scanner/DeviceStorage.swift",
                "Services/Scanner/ScannerService.swift",
                "Services/Offload/Destination.swift",
                "Services/Offload/VerificationGate.swift",
                "Services/Offload/StreamingHasher.swift",
                "Services/Offload/OffloadMeterStore.swift",
                "Services/Offload/HistoryCSVExporter.swift",
                "Services/Smart/SmartPlanner.swift",
                "Services/Coach/CoachService.swift",
                "Services/Pendrive/PendriveMath.swift",
            ]
        ),
        .testTarget(
            name: "OffloadProTests",
            dependencies: [
                "OffloadPro",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "OffloadProTests"
        ),
    ]
)
