// swift-tools-version: 6.2

import PackageDescription

// The latency spike (docs/plan.md, Phase 0 step 6): a command-line tool that measures which chat
// model and effort answer fastest, by voice, while still sounding like Claude.
let package = Package(
  name: "Latency",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "latency", targets: ["Latency"])
  ],
  dependencies: [
    .package(path: "../../UrielCore")
  ],
  targets: [
    .executableTarget(
      name: "Latency", dependencies: [.product(name: "UrielCore", package: "UrielCore")]),
    .testTarget(name: "LatencyTests", dependencies: ["Latency"]),
  ],
  swiftLanguageModes: [.v6]
)
