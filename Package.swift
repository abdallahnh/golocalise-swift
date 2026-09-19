// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "GoLocalise",
  platforms: [
    .iOS(.v15),
    .macOS(.v12),
  ],
  products: [
    .library(name: "GoLocalise", targets: ["GoLocalise"])
  ],
  targets: [
    .target(name: "GoLocalise"),
    .testTarget(
      name: "GoLocaliseTests",
      dependencies: ["GoLocalise"],
      resources: [
        .copy("Fixtures/golden.json")
      ]
    ),
  ]
)
