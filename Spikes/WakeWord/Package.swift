// swift-tools-version: 6.2

import PackageDescription

// The wake-word spike (docs/plan.md, Phase 0 step 7): a command-line tool that records the owner's
// calls and background audio, replays them through each wake-word engine, and scores the results.
let package = Package(
  name: "WakeWord",
  platforms: [.macOS(.v26)],
  products: [
    .executable(name: "wakeword", targets: ["WakeWord"])
  ],
  targets: [
    .executableTarget(name: "WakeWord"),
    .testTarget(name: "WakeWordTests", dependencies: ["WakeWord"]),
  ],
  swiftLanguageModes: [.v6]
)
