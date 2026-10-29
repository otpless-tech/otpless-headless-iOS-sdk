// Steps 2–4 — build the xcframework, audit it for brand leaks and API drift, and package the deliverable.
import CryptoKit
import Foundation

/// Archives the generated framework for device (generic/platform=iOS) and simulator
/// (generic/platform=iOS Simulator), then merges both, with their dSYMs, into one .xcframework.
/// - Parameters:
///   - mapping: module name comes from here.
///   - root: generated module directory containing <module>.xcodeproj.
///   - work: scratch directory; archives/, DerivedData/ and xcframework/ are created inside it.
/// - Returns: work/xcframework/<module>.xcframework.
/// - Throws: WhitelabelError if an archive or -create-xcframework fails (compile errors included).
public func build(_ mapping: Mapping, root: URL, work: URL) throws -> URL {
    let module = mapping.module, archives = work.appendingPathComponent("archives")
    let xcf = work.appendingPathComponent("xcframework/\(module).xcframework")
    remove(archives)
    remove(xcf)
    // One archive per platform; each contributes its .framework (+ dSYM) to -create-xcframework
    var create = ["xcodebuild", "-create-xcframework"]
    for (name, destination) in [("ios", "generic/platform=iOS"), ("ios-simulator", "generic/platform=iOS Simulator")] {
        let archive = archives.appendingPathComponent("\(name).xcarchive")
        log("archiving \(name)")
        try run(["xcodebuild", "archive", "-quiet", "-project", root.appendingPathComponent("\(module).xcodeproj").path, "-scheme", module,
                 "-configuration", "Release", "-destination", destination, "-archivePath", archive.path,
                 "-derivedDataPath", work.appendingPathComponent("DerivedData").path], capture: true)
        create += ["-framework", archive.appendingPathComponent("Products/Library/Frameworks/\(module).framework").path]
        let dsym = archive.appendingPathComponent("dSYMs/\(module).framework.dSYM")
        if dsym.exists {
            create += ["-debug-symbols", dsym.path]
        }
    }
    log("creating xcframework")
    try run(create + ["-output", xcf.path], capture: true)
    return xcf
}

/// A .swiftinterface's text without the `// swift-…` header lines (compiler version and flags), which change
/// with every Xcode update without any API change.
/// - Parameter url: a .swiftinterface file (built or golden).
func normalizedInterface(_ url: URL) throws -> String {
    try readText(url).split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("// swift-") }.joined(separator: "\n")
}

/// Checks the built xcframework, failing on the first category of problem found:
/// 1. brand leaks: `strings` over every shipped file, then the demangled symbol table; matches covered by
///    the preserved entries (Rewriter.stripAllowed) are fine, anything else is a leak.
/// 2. API drift: the arm64 .swiftinterface vs the committed golden whitelabel/api/<module>.swiftinterface
///    (created on the first run; overwritten with --update-api).
/// - Parameters:
///   - rewriter: reused for its brand pattern and allow-list.
///   - xcf: the built .xcframework.
///   - work: scratch directory, for the diff's temporary files.
///   - updateApi: true to overwrite the golden instead of comparing against it.
/// - Throws: WhitelabelError listing every leak (file / symbol and the offending text), or the unified diff of
///   the public API vs the golden.
public func audit(_ rewriter: Rewriter, xcf: URL, work: URL, updateApi: Bool) throws {
    let module = rewriter.mapping.module
    /// True if `line` still contains the brand once the allowed occurrences are removed.
    func leaks(_ line: Substring) -> Bool {
        rewriter.brand.search(rewriter.stripAllowed(String(line)))
    }

    // Brand leaks: every shipped file except dSYMs, read the way a curious merchant would
    var found = Set<String>()
    for file in files(under: xcf, where: { !$0.path.contains(".dSYM") && !$0.pathComponents.contains("_CodeSignature") }) {
        // No -a: skip __TEXT,__text, where x86_64 inlines ≤15-byte literals as instruction immediates
        // (those short literals are already classified at source level)
        for line in try run(["strings", "-n", "4", file.path], capture: true).split(separator: "\n") where leaks(line) {
            found.insert("    \(file.relative(to: xcf)): \(line.trimmingCharacters(in: .whitespaces).prefix(160))")
        }
    }
    // Symbol table: `strings` never reads it, and Swift mangling compresses repeated words, so the brand may
    // not appear literally — demangle to the names a decompiler would show, then scan
    let slices = (try? FileManager.default.contentsOfDirectory(at: xcf, includingPropertiesForKeys: nil)) ?? []
    for binary in slices.map({ $0.appendingPathComponent("\(module).framework/\(module)") }).filter(\.exists) {
        let symbols = try runData(["nm", "-a", binary.path], capture: true)
        for line in try run(["xcrun", "swift-demangle"], capture: true, input: symbols).split(separator: "\n") where leaks(line) {
            found.insert("    \(binary.relative(to: xcf)) (symbol): \(line.trimmingCharacters(in: .whitespaces).prefix(160))")
        }
    }
    guard found.isEmpty else {
        throw WhitelabelError("brand strings leaked into the xcframework:\n" + found.sorted().joined(separator: "\n"))
    }
    log("brand audit clean")
    // Public API golden — the iOS equivalent of the Android BCV .api file
    let interface = xcf.appendingPathComponent("ios-arm64/\(module).framework/Modules/\(module).swiftmodule/arm64-apple-ios.swiftinterface")
    guard interface.exists else { throw WhitelabelError("arm64-apple-ios.swiftinterface not found in the xcframework") }
    let golden = Paths.here.appendingPathComponent("api/\(module).swiftinterface"), current = try normalizedInterface(interface)
    if updateApi || !golden.exists {
        try writeText(current, to: golden)
        log("\(updateApi ? "updated" : "created") API golden \(golden.relative(to: Paths.repo)) — commit it")
        return
    }
    // diff -u of the normalized texts; exit status 1 just means they differ
    let dir = work.appendingPathComponent("api-diff"), old = dir.appendingPathComponent("golden"), new = dir.appendingPathComponent("built")
    try writeText(normalizedInterface(golden), to: old)
    try writeText(current, to: new)
    let diff = try run(["diff", "-u", "--label", golden.relative(to: Paths.repo), "--label", "built", old.path, new.path], capture: true, allowed: [0, 1])
    guard diff.isEmpty else {
        throw WhitelabelError("public API changed vs the committed golden. Review the diff, then rerun with --update-api and commit the golden:\n\(diff)")
    }
    log("public API matches golden")
}

/// Produces the deliverable: optionally codesigns the xcframework, copies it to `out`, and writes
/// <module>-<version>.xcframework.zip plus its .sha256 (the SPM binaryTarget checksum).
/// - Parameters:
///   - mapping: module name comes from here.
///   - xcf: the built and audited .xcframework.
///   - out: output directory (default whitelabel/build/); created if missing.
///   - version: SDK version, used in the zip name.
///   - sign: codesign identity, or nil to ship unsigned.
/// - Returns: the zip.
/// - Throws: WhitelabelError if codesign or ditto fails.
public func package(_ mapping: Mapping, xcf: URL, out: URL, version: String, sign: String?) throws -> URL {
    if let sign {
        log("signing with \"\(sign)\"")
        try run(["codesign", "--timestamp", "--force", "--sign", sign, xcf.path])
    }
    try makeDirs(out)
    let dest = out.appendingPathComponent(xcf.lastPathComponent), archive = out.appendingPathComponent("\(mapping.module)-\(version).xcframework.zip")
    remove(dest)
    remove(archive)
    // copyItem keeps symlinks as symlinks; ditto (not a zip library) preserves the framework's layout and signature
    try FileManager.default.copyItem(at: xcf, to: dest)
    try run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", dest.path, archive.path])
    let checksum = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
    try writeText("\(checksum)  \(archive.lastPathComponent)\n", to: URL(fileURLWithPath: archive.path + ".sha256"))
    return archive
}
