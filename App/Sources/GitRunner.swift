import Foundation

/// Runs `git` for one working tree. Every call is synchronous; callers stay off the
/// main thread.
struct GitRunner {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// What a review is diffed against.
    struct Base: Equatable {
        /// The ref asked for (or found), e.g. `origin/main`; `HEAD` when nothing better exists.
        var ref: String
        /// The commit or tree actually diffed against: the merge-base of `HEAD` and `ref`.
        var sha: String
        /// Set when the base is a fallback the user should know about.
        var notice: String?

        var label: String { "\(ref) @ \(sha.prefix(7))" }
    }

    let root: URL

    /// Output beyond this is not a diff anyone will read; the run is cut short.
    static let outputLimit = 32 * 1024 * 1024

    // MARK: - Queries

    /// Resolves the base for a review. `requested` is a ref, or empty for the default
    /// branch. The diff is taken from the merge-base rather than the ref itself, so it
    /// shows what this branch changed and not what the other branch did meanwhile —
    /// the same thing a pull request shows.
    func resolveBase(_ requested: String) throws -> Base {
        guard let head = try? text(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]) else {
            // No commits yet: everything is new relative to the empty tree.
            let empty = try text(["hash-object", "-t", "tree", "/dev/null"])
            return Base(ref: "empty tree", sha: empty, notice: "This repository has no commits yet.")
        }
        var ref = requested
        if ref.isEmpty {
            var candidates = ["origin/main", "origin/master", "main", "master"]
            if let remoteHead = try? text(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"]) {
                candidates.insert(remoteHead, at: 0)
            }
            guard let found = candidates.first(where: { exists($0) }) else {
                return Base(ref: "HEAD", sha: head,
                            notice: "No default branch found; showing uncommitted changes only.")
            }
            ref = found
        } else if !exists(ref) {
            throw Failure(message: "“\(ref)” is not a commit in this repository.")
        }
        if let mergeBase = try? text(["merge-base", "HEAD", ref]) {
            return Base(ref: ref, sha: mergeBase)
        }
        // Unrelated histories: there is no fork point, so compare with the ref itself.
        return Base(ref: ref, sha: try text(["rev-parse", "--verify", ref + "^{commit}"]))
    }

    /// The unified diff from `base` to the working tree (so uncommitted work is
    /// included). Every flag that user config could flip is pinned, because the parser
    /// depends on the exact shape of the output.
    func diff(against base: String) throws -> String {
        let data = try run([
            "-c", "core.quotePath=false", "diff", "--no-color", "--no-ext-diff", "--no-textconv",
            "-M", "--full-index", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "-U3",
            base, "--",
        ])
        return String(decoding: data, as: UTF8.self)
    }

    /// Paths git neither tracks nor ignores. `git diff` never mentions these, yet a
    /// file an agent has just created is exactly what a review needs to show.
    func untrackedPaths() throws -> [String] {
        let data = try run(["ls-files", "--others", "--exclude-standard", "-z"])
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            // A trailing slash is a nested repository, listed as a directory.
            .filter { !$0.hasSuffix("/") }
    }

    /// A file's contents at `commit`, or nil if it is not there or is not text.
    func contents(of path: String, at commit: String) -> String? {
        guard let data = try? run(["cat-file", "blob", "\(commit):\(path)"]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Running

    private func exists(_ ref: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"])) != nil
    }

    private func text(_ arguments: [String]) throws -> String {
        let output = String(decoding: try run(arguments), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else { throw Failure(message: "git \(arguments.first ?? "") printed nothing") }
        return output
    }

    func run(_ arguments: [String]) throws -> Data {
        try Self.run(arguments, in: root)
    }

    /// The working tree containing `directory`, or nil if it is not in one.
    static func worktreeRoot(containing directory: URL) -> URL? {
        guard let data = try? run(["rev-parse", "--show-toplevel"], in: directory) else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    static func run(_ arguments: [String], in directory: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        var environment = ProcessInfo.processInfo.environment
        // Without this, `git diff` and `git status` opportunistically rewrite the index.
        // That write would wake the repo watcher (an endless refresh loop) and take
        // `index.lock` out from under an agent committing in the same tree.
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw Failure(message: "Could not run git: \(error.localizedDescription)")
        }

        // Both pipes are drained while the process runs: a pipe holds 64 KB, and a
        // process blocked writing to a full one never exits.
        var errorData = Data()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        var output = Data()
        var truncated = false
        while true {
            let chunk = stdout.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            output.append(chunk)
            if output.count > outputLimit {
                truncated = true
                process.terminate()
                break
            }
        }
        group.wait()
        process.waitUntilExit()

        if truncated { throw Failure(message: "The diff is too large to display (over 32 MB).") }
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw Failure(message: message.isEmpty ? "git exited with status \(process.terminationStatus)" : message)
        }
        return output
    }
}
