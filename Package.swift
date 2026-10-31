// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "OSwind", platforms: [.macOS(.v14)],
    products: [.library(name: "OSwindCore", targets: ["OSwindCore"]), .executable(name: "OSwind", targets: ["OSwind"]), .executable(name: "oswindctl", targets: ["OSwindCLI"]), .executable(name:"oswind-preparation-guardian",targets:["OSwindPreparationGuardian"])],
    dependencies: [
        .package(url:"https://github.com/unum-cloud/USearch",exact:"2.26.5"),
        .package(url:"https://github.com/huggingface/swift-transformers.git",exact:"1.3.5"),
        .package(url:"https://github.com/huggingface/swift-jinja.git",exact:"2.5.2"),
        .package(url:"https://github.com/FluidInference/FluidAudio.git",exact:"0.17.7",traits:[])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(name:"OSwindPreparationGuardian"),
        .target(name:"CPIIRuntime",path:"Vendor/ONNXRuntime",exclude:["LICENSE","README.md","provenance.json"],sources:["PIIRuntime.cpp"],publicHeadersPath:"include",cxxSettings:[.headerSearchPath("vendor")]),
        .target(name:"OSwindTokenizers",dependencies:[.product(name:"Hub",package:"swift-transformers"),.product(name:"Jinja",package:"swift-jinja")],path:"Vendor/OSwindTokenizers/Sources"),
        .target(name: "OSwindCore", dependencies: ["CSQLite","OSwindTokenizers","CPIIRuntime",.product(name:"USearch",package:"USearch"),.product(name:"FluidAudio",package:"FluidAudio"),.product(name:"Hub",package:"swift-transformers")], linkerSettings: [.linkedFramework("Accelerate"), .linkedFramework("NaturalLanguage"), .linkedFramework("Metal"), .linkedFramework("MetalPerformanceShaders")]),
        .executableTarget(name: "OSwind", dependencies: ["OSwindCore"]),
        .executableTarget(name: "OSwindCLI", dependencies: ["OSwindCore"]),
        .testTarget(name: "OSwindCoreTests", dependencies: ["OSwindCore","OSwindTokenizers",.product(name:"FluidAudio",package:"FluidAudio")],resources:[.copy("Fixtures/NativeANN")]),
        .testTarget(name: "OSwindAppTests", dependencies: ["OSwind", "OSwindCore"])
    ], swiftLanguageModes: [.v5],cxxLanguageStandard:.cxx17
)
