#!/usr/bin/env python3
"""
Tests for build_whitelabel.lex(), the lexer that decides which parts of a Swift file are code,
string-literal contents or comments (and so which rename rules apply to them).

    python3 whitelabel/tests/test_lex.py                # all tests
    python3 whitelabel/tests/test_lex.py -k LexCases    # hand-written cases only (no Swift build)

LexCases               hand-written edge cases with their exact expected segments, plus the
                       error cases. Fast, stdlib only.
LexMatchesSwiftSyntax  oracle test: every Swift file the build rewrites (SOURCES at `main`, the
                       same snapshot build_whitelabel.py uses) and every LexCases input is lexed
                       by both lex() and tests/swift_segments, a helper built on SwiftSyntax
                       (Apple's own Swift parser). Every non-whitespace character must get the
                       same kind from both (see test_matches_swift_syntax). The first run
                       compiles swift-syntax (~40 s); skipped if no Swift toolchain is installed.
"""
from __future__ import annotations
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from build_whitelabel import HERE, WhitelabelError, export_ref, lex, load_mapping, run, spm_checkout  # noqa: E402

# SwiftPM package of the SwiftSyntax-based oracle
HELPER = Path(__file__).resolve().parent / 'swift_segments'
# Git ref whose sources the oracle test lexes; same default as build_whitelabel.py --ref
REF = 'main'

# (name, Swift source, expected [kind, text] segments)
CASES = [
    ('interpolation', 'log("hi \\(Otpless.shared.x)") // note',
     [['code', 'log("'], ['string', 'hi '], ['code', '\\(Otpless.shared.x)") '], ['comment', '// note']]),
    ('nested interpolation', 'f("a\\(g("b", (1)))c")',
     [['code', 'f("'], ['string', 'a'], ['code', '\\(g("'], ['string', 'b'], ['code', '", (1)))'], ['string', 'c'], ['code', '")']]),
    ('escaped quote', 'let s = "say \\"otpless\\""',
     [['code', 'let s = "'], ['string', 'say \\"otpless\\"'], ['code', '"']]),
    ('raw string', 'let s = #"a "q" \\(x) \\#(y)"#',
     [['code', 'let s = #"'], ['string', 'a "q" \\(x) '], ['code', '\\#(y)"#']]),
    ('multi-line string', 'let s = """\n    line "1"\n    """\n',
     [['code', 'let s = """'], ['string', '\n    line "1"\n    '], ['code', '"""\n']]),
    ('empty string', 'f("")', [['code', 'f("")']]),
    ('comment markers in string', 'let u = "https://x /* y"',
     [['code', 'let u = "'], ['string', 'https://x /* y'], ['code', '"']]),
    ('quote in comment', '// it\'s "otpless"\nlet x = 1',
     [['comment', '// it\'s "otpless"'], ['code', '\nlet x = 1']]),
    ('nested block comment', 'let a = 1 /* x /* y */ z */ + 2',
     [['code', 'let a = 1 '], ['comment', '/* x /* y */ z */'], ['code', ' + 2']]),
    ('doc comment', '/// Otpless entry point\nfunc f() {}',
     [['comment', '/// Otpless entry point'], ['code', '\nfunc f() {}']]),
]


class LexCases(unittest.TestCase):
    """Hand-written inputs whose exact segmentation is known."""

    def test_cases(self) -> None:
        """Each case lexes to exactly its expected segments."""
        for name, src, expected in CASES:
            with self.subTest(name):
                self.assertEqual(lex(src), expected)

    def test_invariants(self) -> None:
        """Segments rebuild the source exactly and adjacent segments never share a kind."""
        for name, src, _ in CASES:
            with self.subTest(name):
                segs = lex(src)
                self.assertEqual(''.join(text for _, text in segs), src)
                self.assertTrue(all(a[0] != b[0] for a, b in zip(segs, segs[1:])))

    def test_unterminated(self) -> None:
        """Unclosed comments, strings and interpolations raise instead of mis-lexing the rest."""
        for src in ('/* a /* b */', 'let s = "abc', 'let s = "\\(a', 'let s = #"abc"'):
            with self.subTest(src), self.assertRaises(WhitelabelError):
                lex(src)


class LexMatchesSwiftSyntax(unittest.TestCase):
    """lex() agrees with Apple's Swift parser on every real SDK source file and every case."""

    @classmethod
    def setUpClass(cls) -> None:
        """Builds the SwiftSyntax helper and collects the corpus: SOURCES at REF plus CASES."""
        if not shutil.which('swift'):
            raise unittest.SkipTest('Swift toolchain not found')
        run(['swift', 'build', '--package-path', HELPER], capture=True)
        cls.helper = Path(run(['swift', 'build', '--package-path', HELPER, '--show-bin-path'], capture=True).strip()) / 'swift-segments'
        cls.tmp = Path(tempfile.mkdtemp(prefix='lex-test-'))
        # Same inputs the build rewrites: non-SPM sources from the git snapshot, vendored ones from the pinned checkout
        m = load_mapping(HERE / 'authio_mapping.py')
        src, _ = export_ref(m, REF, cls.tmp / 'src')
        cls.files = sorted(f for s in m.SOURCES for f in ((spm_checkout(s['spm_package'], src) if 'spm_package' in s else src) / s['path']).rglob('*.swift'))
        for i, (_, case, _) in enumerate(CASES):
            path = cls.tmp / 'cases' / f'case{i}.swift'
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(case)
            cls.files.append(path)

    @classmethod
    def tearDownClass(cls) -> None:
        """Removes the snapshot and case files."""
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_matches_swift_syntax(self) -> None:
        """Every non-whitespace character gets the same kind from lex() and from SwiftSyntax.
        Whitespace is ignored on purpose: inside a multi-line \"\"\" string, SwiftSyntax files the
        newline after the opening delimiter, each line's indentation and the final newline under
        code (the compiler strips them from the value), while lex() keeps them in the string. That
        can't change a rename, since whitespace never contains the brand. A mismatch reports the
        first differing character with its line and surrounding text."""
        self.assertGreater(len(self.files), len(CASES), 'no SDK sources found')
        oracle = json.loads(run([self.helper, *self.files], capture=True))
        for path in self.files:
            with self.subTest('/'.join(path.parts[-3:])):
                src = path.read_text()
                got, want = kinds(lex(src)), kinds(oracle[str(path)])
                self.assertEqual(len(want), len(src), 'SwiftSyntax segments do not rebuild the source')
                i = next((i for i, c in enumerate(src) if not c.isspace() and got[i] != want[i]), None)
                if i is not None:
                    self.fail(f'line {src.count(chr(10), 0, i) + 1}: {src[max(0, i - 30):i + 30]!r}\n'
                              f'  lex() says {got[i]!r}, SwiftSyntax says {want[i]!r}')


def kinds(segs: list[list[str]]) -> list[str]:
    """Expands [kind, text] segments into one kind per source character, for position-wise diffs.
    Args:
        segs: segments as returned by lex() or the swift-segments helper.
    Returns:
        A list as long as the source text, holding each character's kind.
    """
    return [kind for kind, text in segs for _ in text]


if __name__ == '__main__':
    unittest.main()
