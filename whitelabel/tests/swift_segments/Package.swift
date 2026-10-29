// swift-tools-version:5.9
// Test oracle for whitelabel/build_whitelabel.py lex(): splits Swift files into code / comment /
// string segments using SwiftSyntax, Apple's own Swift parser. Used only by tests/test_lex.py.
import PackageDescription

let package = Package(
    name: "swift-segments",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "604.0.0"),
    ],
    targets: [
        .executableTarget(name: "swift-segments", dependencies: [
            .product(name: "SwiftParser", package: "swift-syntax"),
            .product(name: "SwiftSyntax", package: "swift-syntax"),
        ]),
    ]
)
