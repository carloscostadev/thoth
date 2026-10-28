// Sources/Thoth/Models/ProjectGroup.swift
import Foundation

struct ProjectGroup: Identifiable, Hashable {
    let name: String
    let projectDirs: [String] // encoded dir names

    var id: String { name }

    /// Decode a Claude projects directory name back to a filesystem path.
    ///
    /// The encoding replaces "/" with "-" and prepends "-", so
    /// "/Users/alice/Documents/Acme/dashboard-frontend"
    /// becomes "-Users-alice-Documents-Acme-dashboard-frontend".
    ///
    /// This implementation uses a heuristic for the common path structure
    /// `/Users/<username>/Documents/<group>/<project>`:
    ///   - The first 3 segments (Users, username, Documents) never contain hyphens.
    ///   - The 4th segment is the group name (assumed to have no hyphens in its real name).
    ///   - Everything after the 4th segment is the project name (may contain hyphens).
    ///
    /// Falls back to the greedy filesystem-based approach for unrecognised structures.
    static func decodePath(_ encoded: String) -> String {
        var cleaned = encoded
        if cleaned.hasPrefix("-") { cleaned.removeFirst() }
        if cleaned.hasSuffix("-") { cleaned.removeLast() }

        // Fast path for the standard ~/Documents structure:
        // parts[0] = "Users", parts[1] = username, parts[2] = "Documents",
        // parts[3] = group (no hyphens assumed), parts[4...] = project segments
        let parts = cleaned.split(separator: "-", omittingEmptySubsequences: false).map(String.init)

        if parts.count >= 3,
           parts[0] == "Users",
           parts[2] == "Documents" {
            let prefix = "/\(parts[0])/\(parts[1])/\(parts[2])"
            guard parts.count >= 4 else { return prefix }
            let group = parts[3]
            guard parts.count >= 5 else { return "\(prefix)/\(group)" }
            let project = parts[4...].joined(separator: "-")
            return "\(prefix)/\(group)/\(project)"
        }

        // Fallback: greedy filesystem-based reconstruction
        var path = ""
        var i = 0
        while i < parts.count {
            var segment = parts[i]
            var testPath = path + "/" + segment
            var j = i + 1
            while j < parts.count {
                let extended = testPath + "-" + parts[j]
                if FileManager.default.fileExists(atPath: extended) {
                    segment += "-" + parts[j]
                    testPath = extended
                    j += 1
                } else {
                    break
                }
            }
            if !FileManager.default.fileExists(atPath: testPath) && j > i + 1 {
                path += "/" + parts[i]
                i += 1
            } else {
                path += "/" + segment
                i = j
            }
        }
        return path
    }

    /// Extract the group name from a real filesystem path (no encoding tricks).
    /// Uses the first segment after `Documents/` when present, falling back to the last segment.
    static func groupName(fromRealPath path: String) -> String {
        let components = path.split(separator: "/").map(String.init)
        if let docIdx = components.firstIndex(of: "Documents"),
           docIdx + 1 < components.count {
            return components[docIdx + 1]
        }
        return components.last ?? "Unknown"
    }

    /// Extract the group name (first directory after Documents/) from a decoded path.
    static func groupName(from decodedPath: String) -> String {
        let components = decodedPath.split(separator: "/").map(String.init)
        if let docIdx = components.firstIndex(of: "Documents"),
           docIdx + 1 < components.count {
            return components[docIdx + 1]
        }
        return components.last ?? "Unknown"
    }

    /// Group of the sessions started in a temporary folder, a scratchpad or a tool worktree whose
    /// project can't be told: one entry at the end of the picker instead of one per folder.
    static let temporaryFoldersName = "Temporary folders"

    /// Folders whose contents are temporary: the user's temporary directory, `/tmp` and
    /// `/var/folders` (with and without the `/private` prefix they resolve to).
    static let temporaryRoots: [String] = {
        var roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders"]
        let own = (NSTemporaryDirectory() as NSString).standardizingPath
        for root in [own, own.hasPrefix("/var/") ? "/private" + own : own] where !root.isEmpty && root != "/" {
            if !roots.contains(where: { root == $0 || root.hasPrefix($0 + "/") }) { roots.append(root) }
        }
        return roots
    }()

    /// Whether `path` is one of `roots` or inside one.
    static func isTemporary(_ path: String, roots: [String] = temporaryRoots) -> Bool {
        roots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// `isTemporary` for a projects/<dir> folder name, for transcripts read without a cwd.
    static func isTemporary(encodedDir dir: String) -> Bool {
        encodedTemporaryRoots.contains { dir == $0 || dir.hasPrefix($0 + "-") }
    }

    private static let encodedTemporaryRoots = temporaryRoots.map(ClaudeDataService.projectDirName(forCwd:))

    /// Picker order: highest all-time cost first (ties by name), `temporaryFoldersName` last.
    static func menuOrder(_ costs: [String: Double]) -> [(name: String, cost: Double)] {
        let entries: [(name: String, cost: Double)] = costs
            .filter { $0.key != temporaryFoldersName }
            .map { (name: $0.key, cost: $0.value) }
        let sorted = entries.sorted { a, b in
            if a.cost != b.cost { return a.cost > b.cost }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        guard let temporary = costs[temporaryFoldersName] else { return sorted }
        return sorted + [(name: temporaryFoldersName, cost: temporary)]
    }

    /// The group of the sessions started in a folder, resolved against every working directory in
    /// the history. Every rule reads only the path, except rule 2, which reads `<cwd>/.git`
    /// through `gitWorktreeRoot`; the rules are tried in this order:
    ///
    /// 1. A folder in `temporaryRoots` (the temporary directory, `/tmp`, `/var/folders`) or a
    ///    Claude Code scratchpad (`…/claude-<uid>/<encoded project>/<session>/scratchpad…`) →
    ///    `temporaryFoldersName`.
    /// 2. A git worktree whose `.git` file points to `<repo>/.git/worktrees/<name>` → `<repo>`.
    /// 3. `<repo>/.claude/worktrees/<name>…` and `<repo>/.worktrees/<name>…` → `<repo>`.
    /// 4. Horus worktrees, `…/parallel-worktrees/<repo name>-<8 hex>/<name>…` → the known folder
    ///    named `<repo name>` that shares the longest path prefix with `cwd` (ties: the first in
    ///    alphabetical order); with none, `temporaryFoldersName`.
    /// 5. Other tool worktrees, a `worktrees` or `<name>-worktrees` folder inside
    ///    `~/Library/Application Support/<app>/` → `temporaryFoldersName` (rule 2 already moved
    ///    those whose `.git` file names their repository).
    /// 6. `<parent>/<name>-worktrees/<wt>…` → `<parent>/<name>` when that is a known folder.
    ///
    /// A repository found by rules 2–6 that is itself temporary also gives `temporaryFoldersName`.
    /// "Known folders" are the working directories in the history that match none of the path
    /// rules (3–6), so the answer depends only on the set of directories, not on the order they
    /// are seen in.
    struct Resolver {
        enum Owner: Equatable {
            case path(String)
            case temporary
        }

        private let known: [String]
        private let temporaryRoots: [String]
        private let gitWorktreeRoot: (String) -> String?

        init(cwds: some Sequence<String>,
             temporaryRoots: [String] = ProjectGroup.temporaryRoots,
             gitWorktreeRoot: @escaping (String) -> String? = Resolver.gitWorktreeRoot(of:)) {
            known = Set(cwds).filter { Self.pathRule($0) == nil }.sorted()
            self.temporaryRoots = temporaryRoots
            self.gitWorktreeRoot = gitWorktreeRoot
        }

        /// Group shown in the project ranking and the picker for sessions started in `cwd`.
        func groupName(forCwd cwd: String) -> String {
            switch owner(of: cwd) {
            case .path(let root): return ProjectGroup.groupName(fromRealPath: root)
            case .temporary: return ProjectGroup.temporaryFoldersName
            case nil: return ProjectGroup.groupName(fromRealPath: cwd)
            }
        }

        /// The project `cwd` belongs to, `.temporary`, or nil when `cwd` is a project folder itself.
        func owner(of cwd: String) -> Owner? {
            if ProjectGroup.isTemporary(cwd, roots: temporaryRoots) { return .temporary }
            if let repo = gitWorktreeRoot(cwd), repo != cwd { return checked(.path(repo)) }
            switch Self.pathRule(cwd) {
            case nil:
                return nil
            case .scratchpad, .toolWorktree:
                return .temporary
            case .repo(let root):
                return checked(.path(root))
            case .parallel(let name):
                let matches = known.filter { ($0 as NSString).lastPathComponent == name }
                guard let best = matches.max(by: { a, b in
                    let la = Self.commonPrefixLength(a, cwd), lb = Self.commonPrefixLength(b, cwd)
                    return la != lb ? la < lb : a > b
                }) else { return .temporary }
                return checked(.path(best))
            case .sibling(let root):
                return known.contains(root) ? checked(.path(root)) : nil
            }
        }

        private func checked(_ owner: Owner) -> Owner {
            if case .path(let root) = owner, ProjectGroup.isTemporary(root, roots: temporaryRoots) { return .temporary }
            return owner
        }

        private enum PathRule: Equatable {
            case scratchpad
            case repo(String)
            case parallel(name: String)
            case toolWorktree
            case sibling(String)
        }

        private static func pathRule(_ cwd: String) -> PathRule? {
            let parts = cwd.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            func join(_ upTo: Int) -> String { parts[..<upTo].joined(separator: "/") }

            for (i, part) in parts.enumerated() where i + 3 < parts.count {
                if part.hasPrefix("claude-"), part.dropFirst("claude-".count).allSatisfy(\.isNumber),
                   parts[i + 1].hasPrefix("-"), parts[i + 3] == "scratchpad" {
                    return .scratchpad
                }
            }
            // Index of `<app>` in `…/Library/Application Support/<app>/…`.
            let appIndex = parts.indices.first { $0 > 0 && parts[$0] == "Application Support" && parts[$0 - 1] == "Library" }
                .map { $0 + 1 }
            for (i, part) in parts.enumerated() where i + 1 < parts.count && !parts[i + 1].isEmpty {
                if part == ".worktrees", i > 0 { return .repo(join(i)) }
                if part == "worktrees", i > 1, parts[i - 1] == ".claude" { return .repo(join(i - 1)) }
                if part == "parallel-worktrees", let name = horusRepoName(parts[i + 1]) {
                    return .parallel(name: name)
                }
                if let appIndex, i > appIndex, part == "worktrees" || part.hasSuffix("-worktrees") {
                    return .toolWorktree
                }
            }
            for (i, part) in parts.enumerated() where i + 1 < parts.count && !parts[i + 1].isEmpty {
                if part.hasSuffix("-worktrees"), part.count > "-worktrees".count {
                    return .sibling(join(i) + "/" + part.dropLast("-worktrees".count))
                }
            }
            return nil
        }

        /// "site-d9470035" → "site".
        private static func horusRepoName(_ folder: String) -> String? {
            guard let dash = folder.lastIndex(of: "-") else { return nil }
            let suffix = folder[folder.index(after: dash)...]
            guard suffix.count == 8, suffix.allSatisfy(\.isHexDigit), dash > folder.startIndex else { return nil }
            return String(folder[..<dash])
        }

        private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
            zip(a.utf8, b.utf8).prefix { $0 == $1 }.count
        }

        /// The main checkout of the git worktree at `cwd`, read from its `.git` file
        /// (`gitdir: <repo>/.git/worktrees/<name>`); nil for anything else, including a missing
        /// folder, a main checkout (`.git` is a directory) and a submodule.
        static func gitWorktreeRoot(of cwd: String) -> String? {
            guard let data = FileManager.default.contents(atPath: cwd + "/.git"), data.count < 4096,
                  let text = String(data: data, encoding: .utf8),
                  text.hasPrefix("gitdir:") else { return nil }
            var gitdir = text.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            if !gitdir.hasPrefix("/") {
                gitdir = ((cwd as NSString).appendingPathComponent(gitdir) as NSString).standardizingPath
            }
            guard let marker = gitdir.range(of: "/.git/worktrees/") else { return nil }
            return String(gitdir[..<marker.lowerBound])
        }
    }

    /// Group encoded directory names by their parent folder after Documents/.
    static func groupDirectories(_ dirs: [String]) -> [ProjectGroup] {
        var groupMap: [String: [String]] = [:]
        for dir in dirs {
            let decoded = decodePath(dir)
            let group = groupName(from: decoded)
            groupMap[group, default: []].append(dir)
        }
        return groupMap.map { ProjectGroup(name: $0.key, projectDirs: $0.value) }
            .sorted { $0.name < $1.name }
    }
}
