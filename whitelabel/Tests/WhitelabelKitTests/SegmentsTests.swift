// segments(): which parts of a Swift file are code, string-literal contents and comments.
import Testing
@testable import WhitelabelKit

/// A hand-written input with its exact expected segmentation.
struct SegmentCase: CustomTestStringConvertible, Sendable {
    let name: String
    let source: String
    let expected: [Segment]
    var testDescription: String { name }
}

let segmentCases: [SegmentCase] = [
    SegmentCase(name: "interpolation", source: #"log("hi \(Otpless.shared.x)") // note"#,
                expected: [Segment(.code, #"log(""#), Segment(.string, "hi "), Segment(.code, #"\(Otpless.shared.x)") "#), Segment(.comment, "// note")]),
    SegmentCase(name: "nested interpolation", source: #"f("a\(g("b", (1)))c")"#,
                expected: [Segment(.code, #"f(""#), Segment(.string, "a"), Segment(.code, #"\(g(""#), Segment(.string, "b"), Segment(.code, #"", (1)))"#), Segment(.string, "c"), Segment(.code, #"")"#)]),
    SegmentCase(name: "escaped quote", source: #"let s = "say \"otpless\"""#,
                expected: [Segment(.code, #"let s = ""#), Segment(.string, #"say \"otpless\""#), Segment(.code, #"""#)]),
    SegmentCase(name: "raw string", source: ##"let s = #"a "q" \(x) \#(y)"#"##,
                expected: [Segment(.code, ##"let s = #""##), Segment(.string, #"a "q" \(x) "#), Segment(.code, ##"\#(y)"#"##)]),
    SegmentCase(name: "multi-line string", source: "let s = \"\"\"\n    line \"1\"\n    two\n    \"\"\"\n",
                expected: [Segment(.code, "let s = \"\"\"\n    "), Segment(.string, "line \"1\"\n"), Segment(.code, "    "), Segment(.string, "two"), Segment(.code, "\n    \"\"\"\n")]),
    SegmentCase(name: "empty string", source: #"f("")"#, expected: [Segment(.code, #"f("")"#)]),
    SegmentCase(name: "comment markers in string", source: #"let u = "https://x /* y""#,
                expected: [Segment(.code, #"let u = ""#), Segment(.string, "https://x /* y"), Segment(.code, #"""#)]),
    SegmentCase(name: "quote in comment", source: "// it's \"otpless\"\nlet x = 1",
                expected: [Segment(.comment, "// it's \"otpless\""), Segment(.code, "\nlet x = 1")]),
    SegmentCase(name: "nested block comment", source: "let a = 1 /* x /* y */ z */ + 2",
                expected: [Segment(.code, "let a = 1 "), Segment(.comment, "/* x /* y */ z */"), Segment(.code, " + 2")]),
    SegmentCase(name: "doc comment", source: "/// Otpless entry point\nfunc f() {}",
                expected: [Segment(.comment, "/// Otpless entry point"), Segment(.code, "\nfunc f() {}")]),
]

/// segments() against hand-written inputs.
@Suite struct SegmentsTests {
    /// Each case splits into exactly its expected segments.
    @Test(arguments: segmentCases)
    func segmentsMatchExpected(_ c: SegmentCase) throws {
        #expect(try segments(c.source, file: c.name) == c.expected)
    }

    /// Segments rebuild the source exactly and adjacent segments never share a kind.
    @Test(arguments: segmentCases)
    func segmentsRebuildSourceAndAlternateKinds(_ c: SegmentCase) throws {
        let segs = try segments(c.source, file: c.name)
        #expect(segs.map(\.text).joined() == c.source)
        #expect(zip(segs, segs.dropFirst()).allSatisfy { $0.kind != $1.kind })
    }

    /// Unclosed comments, strings and interpolations fail instead of being mis-split.
    @Test(arguments: ["/* a /* b */", #"let s = "abc"#, #"let s = "\(a"#, ##"let s = #"abc""##])
    func syntaxErrorsThrow(_ source: String) {
        #expect(throws: WhitelabelError.self) { try segments(source, file: "broken.swift") }
    }

}
