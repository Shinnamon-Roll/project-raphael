// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "UrielCore",
  platforms: [.macOS(.v26)],
  products: [
    .library(name: "UrielCore", targets: ["UrielCore"])
  ],
  targets: [
    .target(name: "UrielCore"),
    .testTarget(name: "UrielCoreTests", dependencies: ["UrielCore"]),
  ],
  swiftLanguageModes: [.v6]
)
