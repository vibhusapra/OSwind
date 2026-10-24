// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "OSwind", platforms: [.macOS(.v14)],
    products: [.library(name: "OSwindCore", targets: ["OSwindCore"]), .executable(name: "OSwind", targets: ["OSwind"]), .executable(name: "oswindctl", targets: ["OSwindCLI"])],
    dependencies: [
        .package(url:"https://github.com/unum-cloud/USearch",exact:"2.26.5"),
        .package(url:"https://github.com/huggingface/swift-transformers.git",exact:"1.3.5"),
        .package(url:"https://github.com/FluidInference/FluidAudio.git",exact:"0.17.7",traits:[])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "OSwindCore", dependencies: ["CSQLite",.product(name:"USearch",package:"USearch"),.product(name:"FluidAudio",package:"FluidAudio"),.product(name:"Tokenizers",package:"swift-transformers"),.product(name:"Hub",package:"swift-transformers")], linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("NaturalLanguage"), .linkedFramework("Metal"), .linkedFramework("MetalPerformanceShaders")]),
        .executableTarget(name: "OSwind", dependencies: ["OSwindCore"]),
        .executableTarget(name: "OSwindCLI", dependencies: ["OSwindCore"]),
        .testTarget(name: "OSwindCoreTests", dependencies: ["OSwindCore",.product(name:"FluidAudio",package:"FluidAudio")]),
        .testTarget(name: "OSwindAppTests", dependencies: ["OSwind", "OSwindCore"])
    ], swiftLanguageModes: [.v5]
)
