// Shared plumbing: paths, errors, logging, running external tools, regex helpers and file helpers.
import Foundation

/// Fixed locations, derived from where this source file lives in the checkout.
public enum Paths {
    /// whitelabel/ — the package root: mapping, API golden, default output dir.
    public static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    /// Repository root (parent of whitelabel/): SDK sources, Package.resolved and .build/ live here.
    public static let repo = here.deletingLastPathComponent()
}

/// A failure the tool explains in one readable message (unmapped tokens, leaks, failed commands, …).
public struct WhitelabelError: Error, CustomStringConvertible {
    public let description: String

    /// - Parameter description: the message printed to the user.
    public init(_ description: String) {
        self.description = description
    }

}

/// Prints a progress line prefixed with [whitelabel], written unbuffered so it interleaves correctly
/// with the output of the tools it runs.
/// - Parameter message: the message to print.
public func log(_ message: String) {
    FileHandle.standardOutput.write(Data("[whitelabel] \(message)\n".utf8))
}

/// Holds data filled in by a background reader; access is ordered by DispatchGroup.wait().
private final class Box: @unchecked Sendable {
    var data = Data()
}

/// Runs an external command (resolved through PATH) and fails loudly if it exits with an unexpected status.
/// - Parameters:
///   - cmd: program and arguments.
///   - cwd: working directory for the command (default: the current one).
///   - capture: true to capture stdout/stderr and return stdout; false to stream output to the terminal.
///   - input: bytes fed to the command's stdin (used to pipe `nm` output into swift-demangle, or a tar stream).
///   - allowed: exit statuses treated as success (`diff` exits 1 when files differ).
/// - Returns: the command's stdout when `capture` is true, otherwise empty data.
/// - Throws: WhitelabelError on any other exit status; with `capture` the last 80 output lines are included,
///   which is where xcodebuild prints compile errors.
@discardableResult
public func runData(_ cmd: [String], cwd: URL? = nil, capture: Bool = false, input: Data? = nil, allowed: Set<Int32> = [0]) throws -> Data {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = cmd
    process.currentDirectoryURL = cwd
    let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
    if capture {
        process.standardOutput = stdout
        process.standardError = stderr
    }
    if input != nil {
        process.standardInput = stdin
    }
    try process.run()
    // Feed stdin and drain both pipes concurrently, so a full pipe buffer never blocks the child
    let group = DispatchGroup(), out = Box(), err = Box()
    if let input {
        DispatchQueue.global().async(group: group) {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
    }
    if capture {
        DispatchQueue.global().async(group: group) { out.data = stdout.fileHandleForReading.readDataToEndOfFile() }
        DispatchQueue.global().async(group: group) { err.data = stderr.fileHandleForReading.readDataToEndOfFile() }
    }
    group.wait()
    process.waitUntilExit()
    guard allowed.contains(process.terminationStatus) else {
        // xcodebuild reports compile errors on stdout; keep the tail, where they are
        let text = "\(String(decoding: out.data, as: UTF8.self))\n\(String(decoding: err.data, as: UTF8.self))".trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = capture ? text.split(separator: "\n", omittingEmptySubsequences: false).suffix(80).joined(separator: "\n") : ""
        throw WhitelabelError("command failed (\(process.terminationStatus)): \(cmd.joined(separator: " "))\n\(detail)")
    }
    return out.data
}

/// Same as runData, decoding stdout as UTF-8 (invalid bytes are replaced, as `strings` output may contain them).
/// - Returns: the command's stdout when `capture` is true, otherwise "".
@discardableResult
public func run(_ cmd: [String], cwd: URL? = nil, capture: Bool = false, input: Data? = nil, allowed: Set<Int32> = [0]) throws -> String {
    String(decoding: try runData(cmd, cwd: cwd, capture: capture, input: input, allowed: allowed), as: UTF8.self)
}

/// An ICU regular expression (NSRegularExpression) with Python-`re`-style helpers over Swift strings.
public struct Pattern {
    let regex: NSRegularExpression

    /// - Parameters:
    ///   - pattern: ICU regex source.
    ///   - caseInsensitive: match ignoring case.
    /// - Throws: WhitelabelError naming the pattern if it doesn't compile.
    public init(_ pattern: String, caseInsensitive: Bool = false) throws {
        do {
            regex = try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
        } catch {
            throw WhitelabelError("invalid regex /\(pattern)/: \(error.localizedDescription)")
        }
    }

    /// Every match in `text`, as ranges of `text`.
    public func matches(in text: String) -> [Range<String.Index>] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    /// The first match's capture groups (index 0 = whole match), or nil when nothing matches.
    public func firstMatch(in text: String) -> [String?]? {
        guard let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
    }

    /// True if the pattern matches anywhere in `text`.
    public func search(_ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Replaces every match, left to right, with what `replacement` returns for it.
    /// - Parameter replacement: receives the matched text and its range in `text`.
    public func sub(_ text: String, _ replacement: (Substring, Range<String.Index>) -> String) -> String {
        var out = "", last = text.startIndex
        for range in matches(in: text) {
            out += text[last..<range.lowerBound] + replacement(text[range], range)
            last = range.upperBound
        }
        return out + text[last...]
    }

    /// Replaces every match with a fixed string (no template expansion).
    public func sub(_ text: String, with fixed: String) -> String {
        sub(text) { _, _ in fixed }
    }

}

/// Number of newlines in `text`.
func newlines<S: StringProtocol>(_ text: S) -> Int {
    text.utf8.reduce(0) { $1 == 10 ? $0 + 1 : $0 }
}

extension URL {
    /// `self` relative to `base` (both symlink-resolved), or the full path if it is not inside `base`.
    func relative(to base: URL) -> String {
        let path = resolvingSymlinksInPath().path, prefix = base.resolvingSymlinksInPath().path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }

    /// True if a file or directory exists at this URL.
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Every file under `dir` (recursively) whose name passes `filter`, sorted by path components like
/// Python's sorted(Path.rglob()) so processing order (and therefore reports) is deterministic.
func files(under dir: URL, where filter: (URL) -> Bool) -> [URL] {
    let all = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])?.compactMap { $0 as? URL } ?? []
    return all.filter { ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false) && filter($0) }
        .sorted { $0.pathComponents.lexicographicallyPrecedes($1.pathComponents) }
}

/// Deletes `url` if it exists (like shutil.rmtree(ignore_errors=True)).
func remove(_ url: URL) {
    try? FileManager.default.removeItem(at: url)
}

/// Creates `dir` and any missing parents.
func makeDirs(_ dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
}

/// Reads a UTF-8 text file.
func readText(_ url: URL) throws -> String {
    try String(contentsOf: url, encoding: .utf8)
}

/// Writes a UTF-8 text file, creating parent directories first.
func writeText(_ text: String, to url: URL) throws {
    try makeDirs(url.deletingLastPathComponent())
    try Data(text.utf8).write(to: url)
}
