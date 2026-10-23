// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "OSwind", platforms: [.macOS(.v14)],
    products: [.library(name: "OSwindCore", targets: ["OSwindCore"]), .executable(name: "OSwind", targets: ["OSwind"]), .executable(name: "oswindctl", targets: ["OSwindCLI"])],
    dependencies: [
        .package(url:"https://github.com/unum-cloud/USearch",exact:"2.26.5")
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "OSwindCore", dependencies: ["CSQLite",.product(name:"USearch",package:"USearch")], linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("NaturalLanguage"), .linkedFramework("Metal"), .linkedFramework("MetalPerformanceShaders")]),
        .executableTarget(name: "OSwind", dependencies: ["OSwindCore"]),
        .executableTarget(name: "OSwindCLI", dependencies: ["OSwindCore"]),
        .testTarget(name: "OSwindCoreTests", dependencies: ["OSwindCore"])
    ], swiftLanguageModes: [.v5]
)
