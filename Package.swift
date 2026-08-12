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
    dependencies: [
        .package(url: "https://github.com/facebook/facebook-ios-sdk.git", from: "17.0.0"),
        .package(url: "https://github.com/otpless-tech/otpless-event-io-ios.git", from: "1.0.0")
    ],
    targets: [
        .target(
            name: "OtplessBM",
            dependencies: [
                .product(name: "FacebookCore", package: "facebook-ios-sdk"),
                .product(name: "FacebookLogin", package: "facebook-ios-sdk"),
                .product(name: "OtplessEventIO", package: "otpless-event-io-ios")
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
