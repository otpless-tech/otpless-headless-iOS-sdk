// Applies the brand mapping to one segment at a time and collects everything it could not classify.
import Foundation

/// Rewrites Swift files through the mapping. rewrite() is called once per source file and never fails on
/// unmapped tokens; it records them in `unmapped` / `unclassified` so check() can report every problem
/// across all files at once. The same instance is reused by audit() (via `brand` and stripAllowed) to scan
/// the built output.
public final class Rewriter {
    public let mapping: Mapping
    /// Any brand occurrence, case-insensitive.
    public let brand: Pattern
    /// A whole identifier containing the brand (OtplessRequest, otplessId).
    let word: Pattern
    /// literals, longest key first so a specific rule beats a shorter overlapping one (ties: alphabetical).
    let literalRules: [(String, String)]
    let preservedLiterals: [Pattern]
    let preservedIdentifiers: Pattern?
    /// `import OtplessEventIO` lines, which must go once that module is merged into this one.
    let vendoredImport: Pattern?
    let publicModifier: Pattern
    /// Unmapped identifier → first location (file:line).
    public private(set) var unmapped: [String: String] = [:]
    /// (location, literal text) of literals still containing the brand after the literal rules.
    public private(set) var unclassified: [(String, String)] = []
    /// Mapping keys that matched at least once, to warn about dead rows.
    public private(set) var used: Set<String> = []

    /// Compiles the mapping's patterns once.
    /// - Parameter mapping: the loaded brand mapping.
    /// - Throws: WhitelabelError if a mapping regex doesn't compile.
    public init(_ mapping: Mapping) throws {
        self.mapping = mapping
        brand = try Pattern(mapping.brandPattern, caseInsensitive: true)
        word = try Pattern("\\w*(?:\(mapping.brandPattern))\\w*", caseInsensitive: true)
        literalRules = mapping.literals.sorted { ($0.key.count, $1.key) > ($1.key.count, $0.key) }.map { ($0.key, $0.value) }
        preservedLiterals = try mapping.preservedLiterals.map { try Pattern($0.pattern) }
        let keep = mapping.preservedIdentifiers.keys.sorted().map(NSRegularExpression.escapedPattern(for:))
        preservedIdentifiers = keep.isEmpty ? nil : try Pattern("\\b(?:\(keep.joined(separator: "|")))\\b")
        let modules = mapping.sources.filter { $0.vendored == true }.map { NSRegularExpression.escapedPattern(for: $0.module) }
        vendoredImport = modules.isEmpty ? nil : try Pattern("(?m)^[ \\t]*(?:@_\\w+[ \\t]+)?import[ \\t]+(?:\(modules.joined(separator: "|")))\\b[^\\n]*\\n?")
        publicModifier = try Pattern("\\bpublic[ \\t]+")
    }

    /// Replaces every brand occurrence in `text` using `generic`, keyed by the matched casing
    /// (Otpless → AuthIo, OTPLESS → AUTHIO, …). A lowercase match directly followed by an uppercase letter
    /// is camelCase and uses `genericCamel` (otplessFoo → authIoFoo). Used only where a wrong guess is
    /// harmless: comments, file names, mapping suggestions.
    /// - Parameter text: any text.
    /// - Returns: `text` with every brand occurrence swapped.
    public func generic(_ text: String) -> String {
        brand.sub(text) { token, range in
            let next = text[range.upperBound...].first
            if token == token.lowercased(), token != token.uppercased(), next?.isUppercase == true {
                return mapping.genericCamel
            }
            return mapping.generic[String(token)] ?? mapping.generic["default"] ?? String(token)
        }
    }

    /// Removes every preservedLiterals match and preservedIdentifiers word from `text`, so any brand that
    /// is still present afterwards is a leak.
    /// - Parameter text: a literal segment, a `strings` line or a demangled symbol.
    /// - Returns: `text` without the allowed brand occurrences.
    public func stripAllowed(_ text: String) -> String {
        let text = preservedLiterals.reduce(text) { $1.sub($0, with: "") }
        return preservedIdentifiers?.sub(text, with: "") ?? text
    }

    /// Renames every brand word in `text` that has an identifiers row; other words are left as they are.
    func renameIdentifiers(_ text: String) -> String {
        word.sub(text) { token, _ in mapping.identifiers[String(token)] ?? String(token) }
    }

    /// Rewrites one code segment. Every word containing the brand is renamed via identifiers; words neither
    /// mapped nor preserved are recorded in `unmapped`. Also drops `import` lines of vendored modules (they
    /// are now part of this module) and, for vendored files, strips `public` so they don't widen the API.
    /// - Parameters:
    ///   - text: the code segment.
    ///   - rel: display path of the source file, for error locations.
    ///   - line: line number where the segment starts, for error locations.
    ///   - vendored: true when the file belongs to a vendored source.
    /// - Returns: the rewritten code.
    func rewriteCode(_ text: String, rel: String, line: Int, vendored: Bool) -> String {
        // Classify on the untouched text so reported line numbers are the original ones
        for range in word.matches(in: text) {
            let token = String(text[range])
            if mapping.identifiers[token] != nil {
                used.insert(token)
            } else if mapping.preservedIdentifiers[token] == nil, unmapped[token] == nil {
                unmapped[token] = "\(rel):\(line + newlines(text[..<range.lowerBound]))"
            }
        }
        // Merge vendored modules into this one, then rename
        var text = vendoredImport?.sub(text, with: "") ?? text
        if vendored {
            text = publicModifier.sub(text, with: "")
        }
        return renameIdentifiers(text)
    }

    /// Rewrites one string-literal segment with the literal rules (longest first). If brand text not
    /// covered by preservedLiterals remains, the segment is recorded in `unclassified`; literals are never
    /// renamed implicitly.
    /// - Parameters:
    ///   - text: the literal's contents (between quotes, around an interpolation, or one line of a `"""` string).
    ///   - loc: "file:line" of the segment, for error messages.
    /// - Returns: the rewritten literal contents.
    func rewriteString(_ text: String, loc: String) -> String {
        var text = text
        for (from, to) in literalRules where text.contains(from) {
            used.insert(from)
            text = text.replacingOccurrences(of: from, with: to)
        }
        if brand.search(stripAllowed(text)) {
            unclassified.append((loc, text))
        }
        return text
    }

    /// Rewrites one comment segment: exact identifier renames first (so doc comments name the same types as
    /// the code), then generic() for any remaining brand text. Never fails.
    /// - Parameter text: the comment, including its // or /* */ markers.
    /// - Returns: the rewritten comment.
    func rewriteComment(_ text: String) -> String {
        generic(renameIdentifiers(text))
    }

    /// Rebrands one file or directory name, e.g. OtplessBMEvents.swift → AuthIoEvents.swift. The part before
    /// the first dot is looked up in identifiers, falling back to generic().
    /// - Parameter name: a single path component.
    /// - Returns: the rebranded path component.
    public func rewriteName(_ name: String) -> String {
        let stem = String(name.prefix { $0 != "." }), rest = name.dropFirst(stem.count)
        if let renamed = mapping.identifiers[stem] {
            used.insert(stem)
            return renamed + rest
        }
        return generic(stem) + rest
    }

    /// Rewrites one whole Swift file: segments it with SwiftSyntax, sends each segment to the code / string
    /// / comment rules, and joins the results back in order.
    /// - Parameters:
    ///   - source: the file's text.
    ///   - rel: display path such as OtplessBM/Otpless.swift (used in error messages).
    ///   - vendored: true for files of a vendored source.
    /// - Returns: the rebranded file text.
    /// - Throws: WhitelabelError if the file doesn't parse.
    public func rewrite(_ source: String, rel: String, vendored: Bool) throws -> String {
        var out = "", line = 1
        for seg in try segments(source, file: rel) {
            switch seg.kind {
            case .code: out += rewriteCode(seg.text, rel: rel, line: line, vendored: vendored)
            case .string: out += rewriteString(seg.text, loc: "\(rel):\(line)")
            case .comment: out += rewriteComment(seg.text)
            }
            line += newlines(seg.text)
        }
        return out
    }

    /// Ends the generate step: fails if anything was unmapped or unclassified, otherwise warns about mapping
    /// rows that matched no source.
    /// - Parameter mappingPath: the mapping file, named in the error so the fix location is clear.
    /// - Throws: WhitelabelError listing every unmapped identifier as a paste-ready identifiers row
    ///   (generic() suggestion + location) and every unclassified literal with its location.
    public func check(mappingPath: URL) throws {
        var problems: [String] = []
        if !unmapped.isEmpty {
            let rows = unmapped.sorted { $0.key < $1.key }.map { "    \"\($0.key)\": \"\(generic($0.key))\",  // \($0.value)" }
            problems.append("\(unmapped.count) brand identifier(s) in code are unmapped. Add each to identifiers (rename) "
                + "or preservedIdentifiers (keep — with a reason):\n" + rows.joined(separator: "\n"))
        }
        if !unclassified.isEmpty {
            let rows = unclassified.map { "    \($0.0)  \"\($0.1)\"" }
            problems.append("\(unclassified.count) string literal(s) still contain the brand. Add a literals rewrite or, "
                + "if it is a backend/wire contract, a preservedLiterals pattern:\n" + rows.joined(separator: "\n"))
        }
        guard problems.isEmpty else {
            throw WhitelabelError("unmapped brand tokens — edit \(mappingPath.relative(to: Paths.repo))\n\n" + problems.joined(separator: "\n\n"))
        }
        // Clean run: flag mapping rows that matched nothing, so the mapping doesn't rot
        let dead = Set(mapping.identifiers.keys).union(mapping.literals.keys).subtracting(used).sorted()
        if !dead.isEmpty {
            log("warning: mapping rows no longer match any source (safe to delete): \(dead.joined(separator: ", "))")
        }
    }

}
