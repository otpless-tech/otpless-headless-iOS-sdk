// The brand mapping (e.g. whitelabel/authio.json5): what to rename, what to keep, and the build identity.
// Field docs live next to the values in the .json5 file; this is only its typed shape.
import Foundation

/// A decoded brand mapping file. Every brand-specific value the tool uses comes from here.
public struct Mapping: Decodable {
    /// One input module whose *.swift files are rewritten into Sources/<dest>/ of the generated module.
    public struct Source: Decodable {
        /// Original module name; `import <module>` lines are dropped once it is vendored in.
        public let module: String
        /// Source dir: repo-relative, or inside the SPM checkout when `spmPackage` is set.
        public let path: String
        /// Directory under the generated Sources/.
        public let dest: String
        /// SPM package identity whose pinned checkout holds `path`.
        public let spmPackage: String?
        /// Merged dependency: its `public` modifiers are stripped so it stays internal.
        public let vendored: Bool?
    }

    /// File and regex (capture group 1) that give the SDK version.
    public struct VersionSource: Decodable {
        public let file: String
        public let pattern: String
    }

    /// A regex whose matches may keep the brand in literals and the binary, with the reason why.
    public struct PreservedLiteral: Decodable {
        public let pattern: String
        public let reason: String
    }

    public let flavor: String
    public let module: String
    public let bundleId: String
    public let deploymentTarget: String
    public let swiftVersion: String
    public let versionSource: VersionSource
    public let brandPattern: String
    public let generic: [String: String]
    public let genericCamel: String
    public let sources: [Source]
    public let resources: [String: String]
    public let identifiers: [String: String]
    public let preservedIdentifiers: [String: String]
    public let literals: [String: String]
    public let preservedLiterals: [PreservedLiteral]

    /// Decodes a mapping file in JSON5 mode (comments and trailing commas allowed).
    /// - Parameter url: the mapping file, e.g. whitelabel/authio.json5.
    /// - Throws: WhitelabelError naming the file and the decoding problem (missing key, wrong type, …),
    ///   or a preserved entry without a reason.
    public static func load(_ url: URL) throws -> Mapping {
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let mapping: Mapping
        do {
            mapping = try decoder.decode(Mapping.self, from: Data(contentsOf: url))
        } catch {
            throw WhitelabelError("cannot read mapping \(url.path): \(error)")
        }
        // A preserved entry without a reason is how wire contracts get renamed by mistake later
        let unexplained = mapping.preservedIdentifiers.filter { $0.value.isEmpty }.map(\.key) + mapping.preservedLiterals.filter { $0.reason.isEmpty }.map(\.pattern)
        guard unexplained.isEmpty else {
            throw WhitelabelError("preserved entries need a reason in \(url.lastPathComponent): \(unexplained.sorted().joined(separator: ", "))")
        }
        return mapping
    }

}
