// Rewriter and Mapping, using the real authio.json5 so the tests also guard the shipped mapping.
import Foundation
import Testing
@testable import WhitelabelKit

/// A fresh Rewriter over whitelabel/authio.json5.
func authio() throws -> Rewriter {
    try Rewriter(Mapping.load(Paths.here.appendingPathComponent("authio.json5")))
}

/// Rewriter rules for code, strings, comments and file names, and the findings it reports.
@Suite struct RewriterTests {
    /// Mapped identifiers are renamed in code, including inside string interpolations.
    @Test func renamesIdentifiersInCodeAndInterpolations() throws {
        let rw = try authio()
        let out = try rw.rewrite(#"let s = "id: \(Otpless.shared.otplessRequest)"; OtplessBM.start()"#, rel: "A.swift", vendored: false)
        #expect(out == #"let s = "id: \(AuthIo.shared.authIoRequest)"; AuthIoSDK.start()"#)
        #expect(rw.unmapped.isEmpty && rw.unclassified.isEmpty)
    }

    /// Literal rules rewrite substrings, longest key first; preserved literals keep the brand.
    @Test func rewritesAndPreservesLiterals() throws {
        let rw = try authio()
        let out = try rw.rewrite(#"q("com.otpless.queue", "OtplessBM.Otpless", "https://api.otpless.app/v1", "otpless.\(id)://otpless")"#, rel: "A.swift", vendored: false)
        #expect(out == #"q("com.authio.queue", "AuthIoSDK.Otpless", "https://api.otpless.app/v1", "otpless.\(id)://otpless")"#)
        // "Otpless" alone has no literal rule, so that literal is reported rather than guessed
        #expect(rw.unclassified.map(\.1) == ["AuthIoSDK.Otpless"])
    }

    /// Brand words without a mapping row are collected with their first location, and check() fails with
    /// paste-ready rows.
    @Test func reportsUnmappedIdentifiersAndLiterals() throws {
        let rw = try authio()
        _ = try rw.rewrite("let a = 1\nlet otplessNew = \"hello otpless\"\nlet otplessId = 2", rel: "Core/A.swift", vendored: false)
        #expect(rw.unmapped == ["otplessNew": "Core/A.swift:2"])
        #expect(rw.unclassified.map(\.0) == ["Core/A.swift:2"])
        let error = try #require(throws: WhitelabelError.self) { try rw.check(mappingPath: Paths.here.appendingPathComponent("authio.json5")) }
        #expect(error.description.contains(#""otplessNew": "authIoNew",  // Core/A.swift:2"#))
    }

    /// Comments get exact renames first, then the generic casing-aware swap; they never fail the build.
    @Test func rewritesCommentsGenerically() throws {
        let rw = try authio()
        let out = try rw.rewrite("/// OtplessRequest for OTPLESS, see otplessHelper and LongClaw\nlet x = 1", rel: "A.swift", vendored: false)
        #expect(out == "/// AuthIoRequest for AUTHIO, see authIoHelper and AuthIo\nlet x = 1")
        #expect(rw.unmapped.isEmpty)
    }

    /// Vendored files lose `import <vendored module>` and `public`; first-party files keep `public`.
    @Test func mergesVendoredModules() throws {
        let rw = try authio()
        let src = "import Foundation\n@_implementationOnly import OtplessEventIO\npublic final class A {}\n"
        #expect(try rw.rewrite(src, rel: "V.swift", vendored: true) == "import Foundation\nfinal class A {}\n")
        #expect(try rw.rewrite(src, rel: "C.swift", vendored: false) == "import Foundation\npublic final class A {}\n")
    }

    /// File names use identifiers rows, falling back to the generic swap.
    @Test func renamesFiles() throws {
        let rw = try authio()
        #expect(rw.rewriteName("OtplessBMEvents.swift") == "AuthIoEvents.swift")
        #expect(rw.rewriteName("OtplessHelpers.swift") == "AuthIoHelpers.swift")
        #expect(rw.rewriteName("Network") == "Network")
    }

    /// The audit allow-list strips preserved literals and identifiers, so only real leaks remain.
    @Test func stripAllowedKeepsOnlyLeaks() throws {
        let rw = try authio()
        #expect(!rw.brand.search(rw.stripAllowed("https://auth.otpless.app/v3 otplessId OTPlessIntelligence")))
        #expect(rw.brand.search(rw.stripAllowed("AuthIoSDK.OtplessLeak")))
    }

}

/// clean() removes the output and scratch dirs and skips missing ones.
@Suite struct CleanTests {
    /// Existing dirs are removed and reported; a missing one is skipped without error.
    @Test func removesExistingDirsAndSkipsMissing() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clean-test-\(UUID().uuidString)")
        let out = tmp.appendingPathComponent("build"), work = tmp.appendingPathComponent("work")
        try writeText("zip", to: out.appendingPathComponent("AuthIoSDK-1.0.xcframework.zip"))
        defer { remove(tmp) }
        #expect(try clean(out: out, work: work) == [out])
        #expect(!out.exists)
        #expect(try clean(out: out, work: work).isEmpty)
    }

}

/// Invariants of the shipped mapping file.
@Suite struct MappingTests {
    /// Rename targets never contain the brand, otherwise the rewrite would reintroduce it.
    @Test func renameTargetsAreBrandFree() throws {
        let rw = try authio()
        let targets = Array(rw.mapping.identifiers.values) + rw.mapping.literals.values + rw.mapping.generic.values + [rw.mapping.genericCamel]
        #expect(targets.filter(rw.brand.search).isEmpty)
    }

    /// Every rename source actually contains the brand, so no row renames unrelated text.
    @Test func renameSourcesContainTheBrand() throws {
        let rw = try authio()
        #expect(Array(rw.mapping.identifiers.keys).filter { !rw.brand.search($0) }.isEmpty)
        #expect(Array(rw.mapping.literals.keys).filter { !rw.brand.search($0) }.isEmpty)
    }

}
