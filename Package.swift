// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "OtplessBM",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "OtplessBM",
            targets: ["OtplessBM"]
        ),
    ],
    targets: [
        .target(
            name: "OtplessBM"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
