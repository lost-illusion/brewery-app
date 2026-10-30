// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "brewery",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "BreweryCore", targets: ["BreweryCore"]),
        .executable(name: "BreweryApp", targets: ["BreweryApp"]),
    ],
    targets: [
        .target(name: "BreweryCore"),
        .executableTarget(name: "BreweryApp", dependencies: ["BreweryCore"]),
        .testTarget(name: "BreweryCoreTests", dependencies: ["BreweryCore"],
                    exclude: ["Fixtures"]),
    ]
)
