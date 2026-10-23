// swift-tools-version: 6.2
import PackageDescription
let package=Package(name:"SpeechProbe",platforms:[.macOS(.v15)],dependencies:[.package(url:"https://github.com/FluidInference/FluidAudio.git",exact:"0.17.7",traits:[])],targets:[.executableTarget(name:"SpeechProbe",dependencies:[.product(name:"FluidAudio",package:"FluidAudio")])],swiftLanguageModes:[.v5])
