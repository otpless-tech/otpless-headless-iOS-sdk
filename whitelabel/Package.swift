// swift-tools-version:5.10
// Whitelabel .xcframework builder — iOS twin of Android's :LongClaw-authio module.
//   swift run --package-path whitelabel whitelabel --help
import PackageDescription

let package = Package(
    name: "whitelabel",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Apple's Swift parser: splits sources into code / string / comment exactly as the compiler does
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .target(name: "WhitelabelKit", dependencies: [
            .product(name: "SwiftParser", package: "swift-syntax"),
            .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
            .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            .product(name: "SwiftSyntax", package: "swift-syntax"),
        ]),
        .executableTarget(name: "whitelabel", dependencies: [
            "WhitelabelKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        .testTarget(name: "WhitelabelKitTests", dependencies: ["WhitelabelKit"]),
    ]
)
