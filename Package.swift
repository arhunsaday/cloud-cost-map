// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CloudCostMap",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CloudCostCore", targets: ["CloudCostCore"]),
        .executable(name: "CloudCostMap", targets: ["CloudCostMap"])
    ],
    targets: [
        // Everything that is not UI: the cost model, providers, attribution,
        // layout geometry and export. No SwiftUI import allowed here, so it can
        // be reused by a CLI, a widget or another app.
        .target(name: "CloudCostCore"),
        .executableTarget(
            name: "CloudCostMap",
            dependencies: ["CloudCostCore"]
        ),
        .testTarget(
            name: "CloudCostCoreTests",
            dependencies: ["CloudCostCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
