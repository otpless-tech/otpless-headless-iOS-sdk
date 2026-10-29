// Step 1 — generate: snapshot the SDK inputs at a git ref and write the rebranded, self-contained module.
import Foundation

/// --ref value meaning "read the working tree as it is" instead of a git snapshot.
public let worktree = "."

/// Snapshots every SDK input at a git ref, so uncommitted or untracked work never reaches the deliverable.
/// Inputs are the non-SPM source paths, resources, the version file and Package.resolved (which pins the
/// vendored SPM dependencies).
/// - Parameters:
///   - mapping: the brand mapping.
///   - ref: any git ref (branch, tag, sha); `worktree` (".") reads the repo as-is instead.
///   - dest: directory to extract the snapshot into; wiped first.
/// - Returns: the root to read inputs from, and a human-readable origin such as "main @ 01f6979ce".
/// - Throws: WhitelabelError if the ref doesn't resolve to a commit or `git archive` fails.
public func exportRef(_ mapping: Mapping, ref: String, dest: URL) throws -> (root: URL, origin: String) {
    if ref == worktree {
        return (Paths.repo, "working tree")
    }
    let sha = try run(["git", "-C", Paths.repo.path, "rev-parse", "--verify", "\(ref)^{commit}"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines)
    let paths = Set(mapping.sources.filter { $0.spmPackage == nil }.map(\.path) + mapping.resources.keys + [mapping.versionSource.file, "Package.resolved"]).sorted()
    remove(dest)
    try makeDirs(dest)
    // git archive | tar keeps the snapshot byte-identical to the commit
    let archive = try runData(["git", "-C", Paths.repo.path, "archive", "--format=tar", sha, "--"] + paths, capture: true)
    try run(["tar", "-x", "-C", dest.path], input: archive)
    return (dest, "\(ref) @ \(sha.prefix(9))")
}

/// Locates the SwiftPM checkout of a dependency, at exactly the revision pinned in the snapshot's
/// Package.resolved. Runs `swift package resolve` if the checkout is missing or at a different revision.
/// - Parameters:
///   - package: SPM package identity, e.g. "otpless-event-io-ios".
///   - src: snapshot root holding the Package.resolved to read the pin from.
/// - Returns: the checkout under <repo>/.build/checkouts/.
/// - Throws: WhitelabelError if the package isn't pinned, or the checkout still doesn't match the pin after resolving.
public func spmCheckout(_ package: String, src: URL) throws -> URL {
    struct Resolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { let revision: String; let version: String? }
            let identity: String
            let state: State
        }
        let pins: [Pin]
    }
    let pins = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: src.appendingPathComponent("Package.resolved"))).pins
    guard let pin = pins.first(where: { $0.identity == package }) else {
        throw WhitelabelError("\(package) is not pinned in Package.resolved")
    }
    // SwiftPM keeps dependency clones in .build/checkouts; resolve (re)fetches if it's missing or moved
    let checkout = Paths.repo.appendingPathComponent(".build/checkouts/\(package)")
    /// The checkout's current commit sha, or nil if it doesn't exist yet.
    func head() throws -> String? {
        checkout.exists ? try run(["git", "-C", checkout.path, "rev-parse", "HEAD"], capture: true).trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }

    if try head() != pin.state.revision {
        log("resolving \(package) @ \(pin.state.version ?? pin.state.revision)")
        try run(["swift", "package", "resolve"], cwd: Paths.repo)
    }
    if try head() != pin.state.revision {
        throw WhitelabelError("\(checkout.path) is not at pinned revision \(pin.state.revision)")
    }
    return checkout
}

/// Reads the SDK version from the version file (the podspec) in the snapshot. It names the zip and becomes
/// the framework's MARKETING_VERSION.
/// - Parameters:
///   - mapping: the brand mapping.
///   - src: snapshot root.
/// - Returns: the version string, e.g. "3.0.2".
/// - Throws: WhitelabelError if the pattern doesn't match.
public func readVersion(_ mapping: Mapping, src: URL) throws -> String {
    let source = mapping.versionSource
    guard let groups = try Pattern(source.pattern).firstMatch(in: readText(src.appendingPathComponent(source.file))), groups.count > 1, let version = groups[1] else {
        throw WhitelabelError("version not found in \(source.file)")
    }
    return version
}

/// Writes the rebranded, self-contained module and its Xcode project to `root`:
///     root/Sources/Core/...              OtplessBM rewritten
///     root/Sources/Vendored/EventIO/...  OtplessEventIO rewritten + demoted to internal
///     root/Sources/Resources/...         resources copied verbatim
///     root/<module>.xcodeproj            generated framework project
/// - Parameters:
///   - rewriter: collects findings across all files.
///   - mappingPath: mapping file path, named in check() errors.
///   - src: snapshot root from exportRef().
///   - root: output directory; wiped first.
///   - version: SDK version for the project's MARKETING_VERSION.
///   - isStatic: true to configure a static framework.
/// - Throws: WhitelabelError on a file-name clash in the merged module, a resource containing the brand, a
///   file that doesn't parse, or any unmapped / unclassified brand token (reported before the project is written).
public func generate(_ rewriter: Rewriter, mappingPath: URL, src: URL, root: URL, version: String, isStatic: Bool) throws {
    let mapping = rewriter.mapping, sources = root.appendingPathComponent("Sources")
    remove(root)
    var seen: [String: String] = [:]
    // Rewrite every Swift file of every source, renaming paths as well as contents
    for spec in mapping.sources {
        let base = try (spec.spmPackage.map { try spmCheckout($0, src: src) } ?? src).appendingPathComponent(spec.path)
        let swiftFiles = files(under: base) { $0.pathExtension == "swift" }
        log("rewriting \(swiftFiles.count) files from \(spec.module)\(spec.vendored == true ? " (vendored)" : "")")
        for file in swiftFiles {
            let rel = file.relative(to: base)
            let dest = ([spec.dest] + rel.split(separator: "/").map { rewriter.rewriteName(String($0)) }).joined(separator: "/")
            // One Swift module cannot hold two files with the same basename
            let name = String(dest.split(separator: "/").last!)
            if let other = seen[name] {
                throw WhitelabelError("file name clash in merged module: \(dest) vs \(other)")
            }
            seen[name] = dest
            try writeText(rewriter.rewrite(readText(file), rel: "\(spec.module)/\(rel)", vendored: spec.vendored == true), to: sources.appendingPathComponent(dest))
        }
    }
    // Resources: copied as-is, so they must already be brand-free
    for (resource, dest) in mapping.resources.sorted(by: { $0.key < $1.key }) {
        let text = try readText(src.appendingPathComponent(resource))
        if rewriter.brand.search(text) {
            throw WhitelabelError("resource \(resource) contains the brand; it is copied verbatim")
        }
        try writeText(text, to: sources.appendingPathComponent(dest))
    }
    // Report every unmapped token across all files at once, then emit the project
    try rewriter.check(mappingPath: mappingPath)
    try writeProject(mapping, root: root, version: version, isStatic: isStatic)
}
