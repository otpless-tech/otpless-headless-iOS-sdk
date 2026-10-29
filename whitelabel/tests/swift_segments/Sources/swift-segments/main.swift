// Usage: swift-segments <file.swift>...
// Prints {"<path>": [[kind, text], ...]} as JSON, kind ∈ code / comment / string, using the same
// segment rules as lex(): string-literal contents are `string`, comment trivia is `comment`, and
// everything else (delimiters, interpolations, whitespace) is `code`; adjacent same-kind pieces merge.
import Foundation
import SwiftParser
import SwiftSyntax

/// Splits one parsed file into merged [kind, text] segments that concatenate back to the source.
func segments(_ tree: SourceFileSyntax) -> [[String]] {
    var segs: [[String]] = []
    func emit(_ kind: String, _ text: String) {
        guard !text.isEmpty else { return }
        if segs.last?[0] == kind { segs[segs.count - 1][1] += text } else { segs.append([kind, text]) }
    }

    func trivia(_ trivia: Trivia) {
        for piece in trivia {
            var text = ""
            piece.write(to: &text)
            switch piece {
            case .lineComment, .blockComment, .docLineComment, .docBlockComment: emit("comment", text)
            default: emit("code", text)
            }
        }
    }

    for token in tree.tokens(viewMode: .sourceAccurate) {
        trivia(token.leadingTrivia)
        if case .stringSegment = token.tokenKind { emit("string", token.text) } else { emit("code", token.text) }
        trivia(token.trailingTrivia)
    }
    return segs
}

var result: [String: [[String]]] = [:]
for path in CommandLine.arguments.dropFirst() {
    let tree = Parser.parse(source: try String(contentsOfFile: path, encoding: .utf8))
    // A parse error means SwiftSyntax's view is unreliable, so fail instead of comparing
    guard !tree.hasError else {
        FileHandle.standardError.write("swift-segments: \(path) has syntax errors\n".data(using: .utf8)!)
        exit(1)
    }
    result[path] = segments(tree)
}
let json = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
FileHandle.standardOutput.write(json)
