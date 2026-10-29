// Whitelabel .xcframework builder — iOS twin of Android's :LongClaw-authio module.
import ArgumentParser
import Foundation
import WhitelabelKit

@main
struct Whitelabel: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "whitelabel",
        abstract: "Builds the rebranded SDK as one audited .xcframework.",
        discussion: """
        Rewrites Sources/OtplessBM (plus the vendored OtplessEventIO dependency) through a brand mapping into a \
        self-contained source tree, builds it as ONE binary .xcframework, and audits the result so no unmapped brand \
        token ships.

          swift run --package-path whitelabel whitelabel                  # generate → build → audit → package
          swift run --package-path whitelabel whitelabel --generate-only  # emit rebranded tree + .xcodeproj only
          swift run --package-path whitelabel whitelabel --update-api     # accept public-API drift into the golden
          swift run --package-path whitelabel whitelabel --ref .          # build the working tree instead of `main`
          swift run --package-path whitelabel whitelabel --clean          # delete whitelabel/build/ and the scratch dir
          swift test --package-path whitelabel                            # run the tool's tests

        SDK sources are taken from a git ref (default `main`) via `git archive`, so uncommitted or untracked work in \
        Sources/ never reaches the deliverable. Only the whitelabel/ tooling runs from the checkout.

        Pipeline
          1. generate  Each Swift file is parsed with SwiftSyntax into code / comment / string-literal segments, \
        and each kind gets its own rule set:
                         code     → every word containing the brand must be in identifiers (rename) or \
        preservedIdentifiers (keep, e.g. Codable keys). Unknown → build fails.
                         strings  → literals substring rewrites; any brand left must match a preservedLiterals \
        pattern (backend hosts) or the build fails. Literals are never renamed implicitly: they are wire contracts \
        the compiler cannot check.
                         comments → rewritten generically (only doc comments ever ship, via .swiftinterface).
                       Vendored modules are merged into the same Swift module: their `import` lines are dropped \
        and `public` is demoted so they don't widen the shipped API.
          2. build     xcodebuild archive for iphoneos + iphonesimulator → -create-xcframework (+ dSYMs). \
        BUILD_LIBRARY_FOR_DISTRIBUTION=YES, so the module is ABI-stable across Swift versions.
          3. audit     every file in the xcframework is scanned with `strings`, and the binary's symbol table with \
        `nm` + `swift-demangle`, for brand tokens; the arm64 .swiftinterface is diffed against the committed golden \
        whitelabel/api/<module>.swiftinterface.
          4. package   optional codesign, then zip + SHA-256 (the SPM binaryTarget checksum).

        Needs Xcode 16+ (synchronized folder groups in the generated project). The build runs in a brand-free temp \
        dir because absolute source paths end up in the binary.
        """
    )

    @Option(help: "Brand mapping file (JSON5).")
    var mapping = Paths.here.appendingPathComponent("authio.json5").path

    @Flag(help: "Emit rebranded sources + .xcodeproj, skip the build.")
    var generateOnly = false

    @Flag(name: .customLong("static"), help: "Build a static framework (default: dynamic).")
    var isStatic = false

    @Option(help: ArgumentHelp("Codesign identity for the xcframework (e.g. \"Apple Distribution: …\").", valueName: "identity"))
    var sign: String?

    @Flag(help: "Overwrite the public-API golden with the built interface.")
    var updateApi = false

    @Option(help: "Scratch dir; must not contain the brand (default: $TMPDIR/<flavor>-whitelabel).")
    var workDir: String?

    @Option(help: "Where the xcframework + zip land.")
    var out = Paths.here.appendingPathComponent("build").path

    @Option(help: "Git ref whose SDK sources are built; '.' = working tree.")
    var ref = "main"

    @Flag(help: "Delete the build output (--out) and the scratch dir (--work-dir), then exit.")
    var clean = false

    /// Runs generate → build → audit → package (stopping after generate with --generate-only), or only
    /// deletes previous build output with --clean. Every
    /// WhitelabelError is printed as one readable message and exits with status 1.
    func run() throws {
        do {
            // Load the brand and pick a brand-free scratch dir
            let mappingURL = URL(fileURLWithPath: mapping).standardizedFileURL
            let rewriter = try Rewriter(Mapping.load(mappingURL)), m = rewriter.mapping
            let work = (workDir.map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("\(m.flavor)-whitelabel")).resolvingSymlinksInPath()
            // Absolute source paths are embedded in the binary — the build dir must be brand-free
            if rewriter.brand.search(work.path) {
                throw WhitelabelError("work dir \(work.path) contains the brand; pass --work-dir elsewhere")
            }
            let outURL = URL(fileURLWithPath: out).standardizedFileURL
            if clean {
                if try WhitelabelKit.clean(out: outURL, work: work).isEmpty { log("nothing to clean") }
                return
            }
            // Snapshot the SDK inputs at --ref and generate the rebranded project
            let (src, origin) = try exportRef(m, ref: ref, dest: work.appendingPathComponent("ref"))
            let version = try readVersion(m, src: src), root = work.appendingPathComponent(m.module)
            log("\(m.module) \(version) (\(isStatic ? "static" : "dynamic")) from \(origin) → \(root.path)")
            try generate(rewriter, mappingPath: mappingURL, src: src, root: root, version: version, isStatic: isStatic)
            if generateOnly {
                log("generated \(root.appendingPathComponent("\(m.module).xcodeproj").path)")
                return
            }
            // Build, audit, package
            let xcf = try build(m, root: root, work: work)
            try audit(rewriter, xcf: xcf, work: work, updateApi: updateApi)
            let archive = try package(m, xcf: xcf, out: outURL, version: version, sign: sign)
            log("done → \(archive.path)")
            log("sha256 \(try String(contentsOfFile: archive.path + ".sha256", encoding: .utf8).split(separator: " ")[0])")
        } catch let error as WhitelabelError {
            FileHandle.standardError.write(Data("\n[whitelabel] ✗ \(error)\n".utf8))
            throw ExitCode(1)
        }
    }

}
