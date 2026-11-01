// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "Faro",
  platforms: [.macOS("14.4")],
  products: [
    .library(name: "FaroCore", targets: ["FaroCore"]),
    .executable(name: "dicta-bench", targets: ["dicta-bench"]),
    .executable(name: "Faro", targets: ["Faro"]),
  ],
  targets: [
    .target(name: "FaroCore"),
    .executableTarget(name: "dicta-bench", dependencies: ["FaroCore"]),
    .executableTarget(name: "dicta-probe", dependencies: ["FaroCore"]),
    .executableTarget(name: "Faro", dependencies: ["FaroCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "FaroCoreTests", dependencies: ["FaroCore"]),
  ]
)
