// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OSwind", platforms: [.macOS(.v14)],
    products: [.library(name: "OSwindCore", targets: ["OSwindCore"]), .executable(name: "OSwind", targets: ["OSwind"]), .executable(name: "oswindctl", targets: ["OSwindCLI"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "OSwindCore", dependencies: ["CSQLite"], linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("NaturalLanguage")]),
        .executableTarget(name: "OSwind", dependencies: ["OSwindCore"]),
        .executableTarget(name: "OSwindCLI", dependencies: ["OSwindCore"]),
        .testTarget(name: "OSwindCoreTests", dependencies: ["OSwindCore"])
    ], swiftLanguageModes: [.v5]
)
