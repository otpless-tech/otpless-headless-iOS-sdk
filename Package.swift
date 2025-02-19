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
        .package(url: "https://github.com/facebook/facebook-ios-sdk.git", from: "17.4.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "8.1.0-vwg-eap-1.0.0")
    ],
    targets: [
        .target(
            name: "OtplessBM",
            dependencies: [
                .product(name: "FacebookCore", package: "facebook-ios-sdk"),
                .product(name: "FacebookLogin", package: "facebook-ios-sdk"),
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS")
            ]
        ),
    ],
    swiftLanguageVersions: [.v5]
)
