#!/usr/bin/env python3
"""
Whitelabel .xcframework builder — iOS twin of Android's :LongClaw-authio module.

Rewrites Sources/OtplessBM (plus the vendored OtplessEventIO dependency) through a brand mapping
into a self-contained source tree, builds it as ONE binary .xcframework, and audits the result so
no unmapped brand token ships.

    python3 whitelabel/build_whitelabel.py                  # generate → build → audit → package
    python3 whitelabel/build_whitelabel.py --generate-only  # emit rebranded tree + .xcodeproj only
    python3 whitelabel/build_whitelabel.py --update-api     # accept public-API drift into the golden
    python3 whitelabel/build_whitelabel.py --ref .          # build the working tree instead of `main`

SDK sources are taken from a git ref (default `main`) via `git archive`, so uncommitted or untracked
work in Sources/ never reaches the deliverable. Only the whitelabel/ tooling runs from the checkout.

Pipeline
  1. generate  Each Swift file is split by a small lexer into code / comment / string-literal
               segments, and each kind gets its own rule set:
                 code     → every word containing the brand must be in IDENTIFIERS (rename) or
                            PRESERVED_IDENTIFIERS (keep, e.g. Codable keys). Unknown → build fails.
                 strings  → LITERALS substring rewrites; any brand left must match a
                            PRESERVED_LITERALS pattern (backend hosts, telemetry values) or the
                            build fails. Literals are never renamed implicitly: they are wire
                            contracts the compiler cannot check.
                 comments → rewritten generically (only doc comments ever ship, via .swiftinterface).
               Vendored modules are merged into the same Swift module: their `import` lines are
               dropped and `public` is demoted so they don't widen the shipped API.
  2. build     xcodebuild archive for iphoneos + iphonesimulator → -create-xcframework (+ dSYMs).
               BUILD_LIBRARY_FOR_DISTRIBUTION=YES, so the module is ABI-stable across Swift versions.
  3. audit     every file in the xcframework (binary, .swiftinterface, headers, plists) is scanned
               with `strings` for brand tokens; the arm64 .swiftinterface is diffed against the
               committed golden whitelabel/api/<Module>.swiftinterface.
  4. package   optional codesign, then zip + SHA-256 (the SPM binaryTarget checksum).

Stdlib only (Python 3.9+). Needs Xcode 16+ (synchronized folder groups in the generated project).
The build runs in a brand-free temp dir because absolute source paths end up in the binary.
"""
from __future__ import annotations
import argparse
import difflib
import hashlib
import importlib.util
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
HERE = Path(__file__).resolve().parent
STR_OPEN = re.compile(r'(#*)("""|")')


class WhitelabelError(Exception):
    pass


def log(msg: str) -> None:
    print(f'[whitelabel] {msg}', flush=True)


def run(cmd: list, cwd: Path | None = None, capture: bool = False) -> str:
    cmd = [str(c) for c in cmd]
    proc = subprocess.run(cmd, cwd=cwd, text=True, capture_output=capture)
    if proc.returncode != 0:
        # xcodebuild reports compile errors on stdout; keep the tail, where they are
        detail = '\n'.join(f'{proc.stdout or ""}\n{proc.stderr or ""}'.strip().splitlines()[-80:]) if capture else ''
        raise WhitelabelError(f'command failed ({proc.returncode}): {" ".join(cmd)}\n{detail}')
    return proc.stdout if capture else ''


# ---------------------------------------------------------------------------------------------
# Swift lexer
# ---------------------------------------------------------------------------------------------

def lex(src: str) -> list[list[str]]:
    """Splits Swift source into [kind, text] segments, kind ∈ {code, comment, string}.

    Concatenating every segment's text gives back `src` exactly. String interpolations `\\(...)`
    are emitted as code, so identifiers inside them are renamed like any other code. Handles
    nested block comments, multi-line strings and raw strings (#"..."#, \\#(...))."""
    segs: list[list[str]] = []
    def emit(kind: str, a: int, b: int) -> None:
        if b <= a:
            return
        if segs and segs[-1][0] == kind:
            segs[-1][1] += src[a:b]
        else:
            segs.append([kind, src[a:b]])
    def block_comment_end(i: int) -> int:
        depth = 0
        while i < len(src):
            if src.startswith('/*', i):
                depth, i = depth + 1, i + 2
            elif src.startswith('*/', i):
                depth, i = depth - 1, i + 2
                if depth == 0:
                    return i
            else:
                i += 1
        raise WhitelabelError('unterminated block comment')
    def string(i: int) -> int:
        m = STR_OPEN.match(src, i)
        close, esc = m.group(2) + m.group(1), '\\' + m.group(1)
        emit('code', i, m.end())
        i = start = m.end()
        while i < len(src):
            if src.startswith(close, i):
                emit('string', start, i)
                emit('code', i, i + len(close))
                return i + len(close)
            if src.startswith(esc, i):
                k = i + len(esc)
                if src.startswith('(', k):
                    # Interpolation: lex the embedded expression as code up to its matching ')'
                    emit('string', start, i)
                    emit('code', i, k + 1)
                    j = code(k + 1, nested=True)
                    emit('code', j, j + 1)
                    i = start = j + 1
                else:
                    i = k + 1
                continue
            i += 1
        raise WhitelabelError('unterminated string literal')
    def code(i: int, nested: bool = False) -> int:
        start, depth = i, 0
        while i < len(src):
            c = src[i]
            if src.startswith('//', i):
                emit('code', start, i)
                j = src.find('\n', i)
                j = len(src) if j < 0 else j
                emit('comment', i, j)
                i = start = j
            elif src.startswith('/*', i):
                emit('code', start, i)
                j = block_comment_end(i)
                emit('comment', i, j)
                i = start = j
            elif STR_OPEN.match(src, i):
                emit('code', start, i)
                i = start = string(i)
            elif nested and c == '(':
                depth, i = depth + 1, i + 1
            elif nested and c == ')':
                if depth == 0:
                    emit('code', start, i)
                    return i
                depth, i = depth - 1, i + 1
            else:
                i += 1
        if nested:
            raise WhitelabelError('unterminated string interpolation')
        emit('code', start, i)
        return i
    code(0)
    return segs


# ---------------------------------------------------------------------------------------------
# Rewriter
# ---------------------------------------------------------------------------------------------

class Rewriter:
    """Applies the brand mapping segment-by-segment and collects everything it could not classify."""

    def __init__(self, m) -> None:
        self.m = m
        self.brand = re.compile(m.BRAND_PATTERN, re.I)
        self.word = re.compile(rf'\w*(?:{m.BRAND_PATTERN})\w*', re.I)
        self.literal_rules = sorted(m.LITERALS.items(), key=lambda kv: -len(kv[0]))
        self.preserved_literals = [re.compile(p) for p in m.PRESERVED_LITERALS]
        self.preserved_identifiers = re.compile(r'\b(?:' + '|'.join(map(re.escape, m.PRESERVED_IDENTIFIERS)) + r')\b') if m.PRESERVED_IDENTIFIERS else None
        modules = '|'.join(re.escape(s['module']) for s in m.SOURCES if s.get('vendored'))
        self.vendored_import = re.compile(rf'(?m)^[ \t]*(?:@_\w+[ \t]+)?import[ \t]+(?:{modules})\b[^\n]*\n?') if modules else None
        self.unmapped: dict[str, str] = {}
        self.unclassified: list[tuple[str, str]] = []
        self.used: set[str] = set()

    def generic(self, text: str) -> str:
        """Case-aware brand swap for comments, file names and mapping suggestions."""
        def swap(mt: re.Match) -> str:
            tok, rest = mt.group(), text[mt.end():mt.end() + 1]
            if tok.islower() and rest[:1].isupper():
                return self.m.GENERIC_CAMEL
            return self.m.GENERIC.get(tok, self.m.GENERIC['default'])
        return self.brand.sub(swap, text)

    def strip_allowed(self, text: str) -> str:
        """Removes every preserved literal / identifier, so whatever brand remains is a leak."""
        for p in self.preserved_literals:
            text = p.sub('', text)
        return self.preserved_identifiers.sub('', text) if self.preserved_identifiers else text

    def rewrite_code(self, text: str, rel: str, line: int, vendored: bool) -> str:
        # Classify on the untouched text so reported line numbers are the original ones
        for mt in self.word.finditer(text):
            tok = mt.group()
            if tok in self.m.IDENTIFIERS:
                self.used.add(tok)
            elif tok not in self.m.PRESERVED_IDENTIFIERS:
                self.unmapped.setdefault(tok, f'{rel}:{line + text.count(chr(10), 0, mt.start())}')
        # Merge vendored modules into this one, then rename
        if self.vendored_import:
            text = self.vendored_import.sub('', text)
        if vendored:
            text = re.sub(r'\bpublic[ \t]+', '', text)
        return self.word.sub(lambda mt: self.m.IDENTIFIERS.get(mt.group(), mt.group()), text)

    def rewrite_string(self, text: str, loc: str) -> str:
        for frm, to in self.literal_rules:
            if frm in text:
                self.used.add(frm)
                text = text.replace(frm, to)
        if self.brand.search(self.strip_allowed(text)):
            self.unclassified.append((loc, text))
        return text

    def rewrite_comment(self, text: str) -> str:
        return self.generic(self.word.sub(lambda mt: self.m.IDENTIFIERS.get(mt.group(), mt.group()), text))

    def rewrite_name(self, name: str) -> str:
        stem, dot, ext = name.partition('.')
        if stem in self.m.IDENTIFIERS:
            self.used.add(stem)
        return self.m.IDENTIFIERS.get(stem, self.generic(stem)) + dot + ext

    def rewrite(self, src: str, rel: str, vendored: bool) -> str:
        out, line = [], 1
        for kind, text in lex(src):
            if kind == 'code':
                out.append(self.rewrite_code(text, rel, line, vendored))
            elif kind == 'string':
                out.append(self.rewrite_string(text, f'{rel}:{line}'))
            else:
                out.append(self.rewrite_comment(text))
            line += text.count('\n')
        return ''.join(out)

    def check(self, mapping_path: Path) -> None:
        """Fails with paste-ready mapping rows for everything unclassified; warns on dead rows."""
        problems = []
        if self.unmapped:
            rows = '\n'.join(f"    {tok!r}: {self.generic(tok)!r},  # {loc}" for tok, loc in sorted(self.unmapped.items()))
            problems.append(f'{len(self.unmapped)} brand identifier(s) in code are unmapped. Add each to IDENTIFIERS '
                            f'(rename) or PRESERVED_IDENTIFIERS (keep — with a reason):\n{rows}')
        if self.unclassified:
            rows = '\n'.join(f'    {loc}  "{text}"' for loc, text in self.unclassified)
            problems.append(f'{len(self.unclassified)} string literal(s) still contain the brand. Add a LITERALS rewrite '
                            f'or, if it is a backend/wire contract, a PRESERVED_LITERALS pattern:\n{rows}')
        if problems:
            raise WhitelabelError(f'unmapped brand tokens — edit {mapping_path.relative_to(REPO)}\n\n' + '\n\n'.join(problems))
        dead = sorted((set(self.m.IDENTIFIERS) | set(self.m.LITERALS)) - self.used)
        if dead:
            log(f'warning: mapping rows no longer match any source (safe to delete): {", ".join(dead)}')


# ---------------------------------------------------------------------------------------------
# Generate
# ---------------------------------------------------------------------------------------------

WORKTREE = '.'


def export_ref(m, ref: str, dest: Path) -> tuple[Path, str]:
    """Snapshots every SDK input (sources, resources, version file, Package.resolved) at `ref`.

    Building from a committed ref keeps uncommitted / untracked work out of the deliverable.
    `ref == '.'` reads the working tree instead (for trying local changes)."""
    if ref == WORKTREE:
        return REPO, 'working tree'
    sha = run(['git', '-C', REPO, 'rev-parse', '--verify', f'{ref}^{{commit}}'], capture=True).strip()
    paths = sorted({s['path'] for s in m.SOURCES if 'spm_package' not in s} | set(m.RESOURCES) | {m.VERSION_SOURCE[0], 'Package.resolved'})
    shutil.rmtree(dest, ignore_errors=True)
    dest.mkdir(parents=True)
    # git archive | tar keeps the snapshot byte-identical to the commit
    archive = subprocess.run(['git', '-C', str(REPO), 'archive', '--format=tar', sha, '--', *paths], capture_output=True)
    if archive.returncode != 0:
        raise WhitelabelError(f'git archive {ref} failed: {archive.stderr.decode().strip()}')
    subprocess.run(['tar', '-x', '-C', str(dest)], input=archive.stdout, check=True)
    return dest, f'{ref} @ {sha[:9]}'


def spm_checkout(package: str, src: Path) -> Path:
    """Returns the SwiftPM checkout of `package`, pinned to the revision in `src`/Package.resolved."""
    pins = json.loads((src / 'Package.resolved').read_text())['pins']
    pin = next((p for p in pins if p['identity'] == package), None)
    if pin is None:
        raise WhitelabelError(f'{package} is not pinned in Package.resolved')
    checkout, want = REPO / '.build' / 'checkouts' / package, pin['state']['revision']
    def head() -> str | None:
        return run(['git', '-C', checkout, 'rev-parse', 'HEAD'], capture=True).strip() if checkout.exists() else None
    if head() != want:
        log(f'resolving {package} @ {pin["state"].get("version", want)}')
        run(['swift', 'package', 'resolve'], cwd=REPO)
    if head() != want:
        raise WhitelabelError(f'{checkout} is not at pinned revision {want}')
    return checkout


def read_version(m, src: Path) -> str:
    file, pattern = m.VERSION_SOURCE
    match = re.search(pattern, (src / file).read_text())
    if not match:
        raise WhitelabelError(f'version not found in {file}')
    return match.group(1)


def generate(m, rw: Rewriter, mapping_path: Path, src: Path, root: Path, version: str, static: bool) -> None:
    shutil.rmtree(root, ignore_errors=True)
    sources, seen = root / 'Sources', {}
    for spec in m.SOURCES:
        base = (spm_checkout(spec['spm_package'], src) if 'spm_package' in spec else src) / spec['path']
        files = sorted(base.rglob('*.swift'))
        log(f'rewriting {len(files)} files from {spec["module"]}{" (vendored)" if spec.get("vendored") else ""}')
        for f in files:
            rel = f.relative_to(base)
            dest = Path(spec['dest'], *[rw.rewrite_name(p) for p in rel.parts])
            # One Swift module cannot hold two files with the same basename
            if dest.name in seen:
                raise WhitelabelError(f'file name clash in merged module: {dest} vs {seen[dest.name]}')
            seen[dest.name] = dest
            out = sources / dest
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(rw.rewrite(f.read_text(), f'{spec["module"]}/{rel}', spec.get('vendored', False)))
    for resource, dest in m.RESOURCES.items():
        text = (src / resource).read_text()
        if rw.brand.search(text):
            raise WhitelabelError(f'resource {resource} contains the brand; it is copied verbatim')
        (sources / dest).parent.mkdir(parents=True, exist_ok=True)
        (sources / dest).write_text(text)
    rw.check(mapping_path)
    write_project(m, root, version, static)


# ---------------------------------------------------------------------------------------------
# Xcode project (synchronized folder group → no per-file bookkeeping)
# ---------------------------------------------------------------------------------------------

PBXPROJ = """// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {
		AA0000000000000000000001 /* __MODULE__.framework */ = {isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = __MODULE__.framework; sourceTree = BUILT_PRODUCTS_DIR; };
		AA0000000000000000000002 /* Sources */ = {isa = PBXFileSystemSynchronizedRootGroup; path = Sources; sourceTree = "<group>"; };
		AA0000000000000000000003 /* Frameworks */ = {isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		AA0000000000000000000004 = {isa = PBXGroup; children = (AA0000000000000000000002, AA0000000000000000000005); sourceTree = "<group>"; };
		AA0000000000000000000005 /* Products */ = {isa = PBXGroup; children = (AA0000000000000000000001); name = Products; sourceTree = "<group>"; };
		AA0000000000000000000006 /* __MODULE__ */ = {isa = PBXNativeTarget; buildConfigurationList = AA0000000000000000000007; buildPhases = (AA0000000000000000000008, AA0000000000000000000003, AA0000000000000000000009); buildRules = (); dependencies = (); fileSystemSynchronizedGroups = (AA0000000000000000000002); name = __MODULE__; productName = __MODULE__; productReference = AA0000000000000000000001; productType = "com.apple.product-type.framework"; };
		AA0000000000000000000007 = {isa = XCConfigurationList; buildConfigurations = (AA000000000000000000000D); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		AA0000000000000000000008 /* Sources */ = {isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		AA0000000000000000000009 /* Resources */ = {isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0; };
		AA000000000000000000000A /* Project object */ = {isa = PBXProject; attributes = {BuildIndependentTargetsInParallel = 1; LastUpgradeCheck = 2600; }; buildConfigurationList = AA000000000000000000000B; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en, Base); mainGroup = AA0000000000000000000004; minimizedProjectReferenceProxies = 1; preferredProjectObjectVersion = 77; productRefGroup = AA0000000000000000000005; projectDirPath = ""; projectRoot = ""; targets = (AA0000000000000000000006); };
		AA000000000000000000000B = {isa = XCConfigurationList; buildConfigurations = (AA000000000000000000000C); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release; };
		AA000000000000000000000C /* Release */ = {isa = XCBuildConfiguration; buildSettings = {__PROJECT_SETTINGS__}; name = Release; };
		AA000000000000000000000D /* Release */ = {isa = XCBuildConfiguration; buildSettings = {__TARGET_SETTINGS__}; name = Release; };
	};
	rootObject = AA000000000000000000000A;
}
"""

SCHEME = """<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
   <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting="NO" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">
            <BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="AA0000000000000000000006" BuildableName="__MODULE__.framework" BlueprintName="__MODULE__" ReferencedContainer="container:__MODULE__.xcodeproj"/>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="NO"/>
</Scheme>
"""


def write_project(m, root: Path, version: str, static: bool) -> None:
    project = {
        'ALWAYS_SEARCH_USER_PATHS': 'NO', 'CLANG_ENABLE_MODULES': 'YES', 'DEBUG_INFORMATION_FORMAT': 'dwarf-with-dsym',
        'ENABLE_TESTABILITY': 'NO', 'ENABLE_USER_SCRIPT_SANDBOXING': 'YES', 'IPHONEOS_DEPLOYMENT_TARGET': m.DEPLOYMENT_TARGET,
        'SDKROOT': 'iphoneos', 'SWIFT_COMPILATION_MODE': 'wholemodule', 'SWIFT_OPTIMIZATION_LEVEL': '-O',
        'SWIFT_VERSION': m.SWIFT_VERSION, 'VALIDATE_PRODUCT': 'YES',
    }
    target = {
        'BUILD_LIBRARY_FOR_DISTRIBUTION': 'YES', 'CODE_SIGNING_ALLOWED': 'NO', 'CURRENT_PROJECT_VERSION': '1',
        'DEFINES_MODULE': 'YES', 'DYLIB_INSTALL_NAME_BASE': '@rpath', 'GENERATE_INFOPLIST_FILE': 'YES',
        'LD_RUNPATH_SEARCH_PATHS': '$(inherited) @executable_path/Frameworks @loader_path/Frameworks',
        'MACH_O_TYPE': 'staticlib' if static else 'mh_dylib', 'MARKETING_VERSION': version,
        'PRODUCT_BUNDLE_IDENTIFIER': m.BUNDLE_ID, 'PRODUCT_NAME': '$(TARGET_NAME)', 'SKIP_INSTALL': 'NO',
        'SUPPORTED_PLATFORMS': 'iphoneos iphonesimulator', 'SUPPORTS_MACCATALYST': 'NO', 'SWIFT_EMIT_LOC_STRINGS': 'NO',
        'SWIFT_INSTALL_OBJC_HEADER': 'YES', 'TARGETED_DEVICE_FAMILY': '1,2',
    }
    render = lambda d: ' '.join(f'{k} = "{v}";' for k, v in sorted(d.items()))
    pbx = PBXPROJ.replace('__PROJECT_SETTINGS__', render(project)).replace('__TARGET_SETTINGS__', render(target))
    proj = root / f'{m.MODULE}.xcodeproj'
    (proj / 'xcshareddata' / 'xcschemes').mkdir(parents=True, exist_ok=True)
    (proj / 'project.pbxproj').write_text(pbx.replace('__MODULE__', m.MODULE))
    (proj / 'xcshareddata' / 'xcschemes' / f'{m.MODULE}.xcscheme').write_text(SCHEME.replace('__MODULE__', m.MODULE))


# ---------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------

def build(m, root: Path, work: Path) -> Path:
    archives, xcf = work / 'archives', work / 'xcframework' / f'{m.MODULE}.xcframework'
    shutil.rmtree(archives, ignore_errors=True)
    shutil.rmtree(xcf, ignore_errors=True)
    create = ['xcodebuild', '-create-xcframework']
    for name, destination in (('ios', 'generic/platform=iOS'), ('ios-simulator', 'generic/platform=iOS Simulator')):
        archive = archives / f'{name}.xcarchive'
        log(f'archiving {name}')
        run(['xcodebuild', 'archive', '-quiet', '-project', root / f'{m.MODULE}.xcodeproj', '-scheme', m.MODULE,
             '-configuration', 'Release', '-destination', destination, '-archivePath', archive,
             '-derivedDataPath', work / 'DerivedData'], capture=True)
        create += ['-framework', archive / 'Products' / 'Library' / 'Frameworks' / f'{m.MODULE}.framework']
        dsym = archive / 'dSYMs' / f'{m.MODULE}.framework.dSYM'
        if dsym.exists():
            create += ['-debug-symbols', dsym]
    log('creating xcframework')
    run(create + ['-output', xcf], capture=True)
    return xcf


# ---------------------------------------------------------------------------------------------
# Audit
# ---------------------------------------------------------------------------------------------

def normalized_interface(path: Path) -> list[str]:
    # Header comments carry the compiler version/flags — they change with every Xcode update
    return [l for l in path.read_text().splitlines(keepends=True) if not l.startswith('// swift-')]


def audit(m, rw: Rewriter, xcf: Path, update_api: bool) -> None:
    # Brand leaks: every shipped file except dSYMs, read the way a curious merchant would
    leaks = []
    for f in sorted(p for p in xcf.rglob('*') if p.is_file() and '.dSYM' not in str(p) and '_CodeSignature' not in p.parts):
        # No -a: skip __TEXT,__text, where x86_64 inlines ≤15-byte literals as instruction immediates
        # (those short literals are already classified at source level)
        for s in run(['strings', '-n', '4', f], capture=True).splitlines():
            if rw.brand.search(rw.strip_allowed(s)):
                leaks.append(f'    {f.relative_to(xcf)}: {s.strip()[:160]}')
    if leaks:
        raise WhitelabelError('brand strings leaked into the xcframework:\n' + '\n'.join(sorted(set(leaks))))
    log('brand audit clean')
    # Public API golden — the iOS equivalent of the Android BCV .api file
    interface = next(xcf.glob(f'ios-arm64/{m.MODULE}.framework/Modules/{m.MODULE}.swiftmodule/arm64-apple-ios.swiftinterface'), None)
    if interface is None:
        raise WhitelabelError('arm64-apple-ios.swiftinterface not found in the xcframework')
    golden = HERE / 'api' / f'{m.MODULE}.swiftinterface'
    current = normalized_interface(interface)
    if update_api or not golden.exists():
        golden.parent.mkdir(parents=True, exist_ok=True)
        golden.write_text(''.join(current))
        log(f'{"updated" if update_api else "created"} API golden {golden.relative_to(REPO)} — commit it')
        return
    diff = list(difflib.unified_diff(normalized_interface(golden), current, str(golden.relative_to(REPO)), 'built'))
    if diff:
        raise WhitelabelError('public API changed vs the committed golden. Review the diff, then rerun with '
                              '--update-api and commit the golden:\n' + ''.join(diff))
    log('public API matches golden')


# ---------------------------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------------------------

def package(m, xcf: Path, out: Path, version: str, sign: str | None) -> Path:
    if sign:
        log(f'signing with "{sign}"')
        run(['codesign', '--timestamp', '--force', '--sign', sign, xcf])
    out.mkdir(parents=True, exist_ok=True)
    dest, archive = out / xcf.name, out / f'{m.MODULE}-{version}.xcframework.zip'
    shutil.rmtree(dest, ignore_errors=True)
    shutil.copytree(xcf, dest, symlinks=True)
    archive.unlink(missing_ok=True)
    run(['ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', dest, archive])
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    Path(f'{archive}.sha256').write_text(f'{checksum}  {archive.name}\n')
    return archive


# ---------------------------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------------------------

def load_mapping(path: Path):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location('whitelabel_mapping', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--mapping', type=Path, default=HERE / 'authio_mapping.py', help='brand mapping file')
    parser.add_argument('--generate-only', action='store_true', help='emit rebranded sources + .xcodeproj, skip the build')
    parser.add_argument('--static', action='store_true', help='build a static framework (default: dynamic)')
    parser.add_argument('--sign', metavar='IDENTITY', help='codesign identity for the xcframework (e.g. "Apple Distribution: …")')
    parser.add_argument('--update-api', action='store_true', help='overwrite the public-API golden with the built interface')
    parser.add_argument('--work-dir', type=Path, help='scratch dir; must not contain the brand (default: $TMPDIR/<flavor>-whitelabel)')
    parser.add_argument('--out', type=Path, default=HERE / 'build', help='where the xcframework + zip land')
    parser.add_argument('--ref', default='main', help="git ref whose SDK sources are built (default: main); '.' = working tree")
    args = parser.parse_args()
    try:
        m = load_mapping(args.mapping.resolve())
        rw = Rewriter(m)
        work = (args.work_dir or Path(tempfile.gettempdir()) / f'{m.FLAVOR}-whitelabel').resolve()
        # Absolute source paths are embedded in the binary — the build dir must be brand-free
        if rw.brand.search(str(work)):
            raise WhitelabelError(f'work dir {work} contains the brand; pass --work-dir elsewhere')
        src, origin = export_ref(m, args.ref, work / 'ref')
        version, root = read_version(m, src), work / m.MODULE
        log(f'{m.MODULE} {version} ({"static" if args.static else "dynamic"}) from {origin} → {root}')
        generate(m, rw, args.mapping.resolve(), src, root, version, args.static)
        if args.generate_only:
            log(f'generated {root / (m.MODULE + ".xcodeproj")}')
            return 0
        xcf = build(m, root, work)
        audit(m, rw, xcf, args.update_api)
        archive = package(m, xcf, args.out.resolve(), version, args.sign)
        log(f'done → {archive}')
        log(f'sha256 {Path(f"{archive}.sha256").read_text().split()[0]}')
        return 0
    except WhitelabelError as e:
        print(f'\n[whitelabel] ✗ {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
