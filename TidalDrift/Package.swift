// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TidalDrift",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "TidalDrift", targets: ["TidalDrift"])
    ],
    targets: [
        .executableTarget(
            name: "TidalDrift",
            path: ".",
            exclude: ["build-release.sh", ".env", ".env.example", ".env.template", "TidalDrift.entitlements", "Info.plist", "Package.swift", "build-app.sh", "Resources/AppIcon.iconset", "Scripts", "PressKit", "dist", "drop", "bump-version.sh", "LocalCast/README.md"],
            sources: [
                "App",
                "Views",
                "ViewModels", 
                "Services",
                "Models",
                "Utilities",
                "LocalCast",
                "Extensions"
            ],
            resources: [
                .copy("Resources/AppIcon.icns"),
                .process("Resources/Assets.xcassets")
            ],
            swiftSettings: [
                .define("DEBUG", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "TidalDriftTests",
            dependencies: ["TidalDrift"],
            path: "Tests/TidalDriftTests"
        )
    ]
)
