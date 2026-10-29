// Splits Swift source into code / string / comment segments using SwiftSyntax, Apple's Swift parser
// (the same parser the compiler, swift-format and SwiftLint use), so the rename rules always see the
// same structure the compiler does.
import SwiftDiagnostics
import SwiftParser
import SwiftParserDiagnostics
import SwiftSyntax

/// Which rule set applies to a piece of source.
public enum SegmentKind: String, Sendable {
    /// Everything outside literals and comments, including literal delimiters, `\(…)` interpolations and whitespace.
    case code
    /// String-literal contents (one segment per run of text between delimiters / interpolations / lines).
    case string
    /// `//`, `///`, `/* */` and `/** */` comments, markers included.
    case comment
}

/// A run of source text of one kind.
public struct Segment: Equatable, Sendable {
    public var kind: SegmentKind
    public var text: String

    /// - Parameters:
    ///   - kind: the segment's kind.
    ///   - text: the exact source text.
    public init(_ kind: SegmentKind, _ text: String) {
        self.kind = kind
        self.text = text
    }

}

/// Splits one Swift file into ordered segments. Concatenating every segment's text gives back `source`
/// exactly, and adjacent segments never share a kind (same-kind pieces are merged).
///   log("hi \(Otpless.shared.x)") // note
///     code     `log("`
///     string   `hi `
///     code     `\(Otpless.shared.x)") `   ← interpolation + closing quote + space, merged
///     comment  `// note`
/// In a multi-line `"""` string, the newline after the opening delimiter, each line's indentation and the
/// final newline are code: the compiler strips them from the value, so only the real contents are string.
/// - Parameters:
///   - source: the full text of one Swift file.
///   - file: display path, used in the syntax-error message.
/// - Returns: the segments in source order.
/// - Throws: WhitelabelError with the parser's diagnostics if the file has syntax errors, since a broken
///   parse could put brand text in the wrong rule set.
public func segments(_ source: String, file: String) throws -> [Segment] {
    let tree = Parser.parse(source: source)
    guard !tree.hasError else {
        let diagnostics = ParseDiagnosticsGenerator.diagnostics(for: tree)
        throw WhitelabelError("\(file) has syntax errors:\n" + DiagnosticsFormatter.annotatedSource(tree: tree, diags: diagnostics))
    }
    var segs: [Segment] = []
    /// Appends `text` as a `kind` segment, extending the previous segment when it has the same kind
    func emit(_ kind: SegmentKind, _ text: String) {
        guard !text.isEmpty else { return }
        if segs.last?.kind == kind { segs[segs.count - 1].text += text } else { segs.append(Segment(kind, text)) }
    }

    /// Emits trivia: comments (trivia attached to tokens) as comment; spaces, newlines and other trivia are code
    func trivia(_ trivia: Trivia) {
        for piece in trivia {
            var text = ""
            piece.write(to: &text)
            switch piece {
            case .lineComment, .blockComment, .docLineComment, .docBlockComment: emit(.comment, text)
            default: emit(.code, text)
            }
        }
    }

    for token in tree.tokens(viewMode: .sourceAccurate) {
        trivia(token.leadingTrivia)
        if case .stringSegment = token.tokenKind { emit(.string, token.text) } else { emit(.code, token.text) }
        trivia(token.trailingTrivia)
    }
    // SwiftSyntax round-trips by design; guard anyway, since a mismatch would corrupt the output file
    guard segs.map(\.text).joined() == source else { throw WhitelabelError("\(file): segments do not rebuild the source") }
    return segs
}
