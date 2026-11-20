// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "ReShot", platforms: [.macOS(.v13)], products: [.executable(name: "ReShot", targets: ["ReShot"])], targets: [.executableTarget(name: "ReShot", path: "Sources/ReShot", linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("Vision"), .linkedFramework("Carbon"), .linkedFramework("ScreenCaptureKit"), .linkedFramework("AVFoundation")])])
