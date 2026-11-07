// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Distee",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Distee", targets: ["Distee"]),
        .executable(name: "distee-devrelay", targets: ["DevRelay"]),
        .executable(name: "distee-tests", targets: ["DisteeTests"]),
        .library(name: "DisteeCore", targets: ["DisteeCore"])
    ],
    targets: [
        .target(
            name: "DisteeCore",
            path: "Sources/DisteeCore"
        ),
        .executableTarget(
            name: "Distee",
            dependencies: ["DisteeCore"],
            path: "Sources/Distee"
        ),
        .target(
            name: "DisteeTestSupport",
            dependencies: ["DisteeCore"],
            path: "Sources/DisteeTestSupport"
        ),
        .executableTarget(
            name: "DevRelay",
            dependencies: ["DisteeCore", "DisteeTestSupport"],
            path: "Sources/DevRelay"
        ),
        .executableTarget(
            name: "DisteeTests",
            dependencies: ["DisteeCore", "DisteeTestSupport"],
            path: "Tests/DisteeTests"
        )
    ]
)
