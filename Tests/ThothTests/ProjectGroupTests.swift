// Tests/ThothTests/ProjectGroupTests.swift
import Foundation
import Testing
@testable import Thoth

@Test func decodeProjectPath() {
    let encoded = "-Users-alice-Documents-Acme-dashboard-frontend"
    let decoded = ProjectGroup.decodePath(encoded)
    #expect(decoded == "/Users/alice/Documents/Acme/dashboard-frontend")
}

@Test func extractGroupName() {
    let path = "/Users/alice/Documents/Acme/dashboard-frontend"
    let group = ProjectGroup.groupName(from: path)
    #expect(group == "Acme")
}

@Test func groupProjectDirs() {
    let dirs = [
        "-Users-alice-Documents-Acme-dashboard-frontend",
        "-Users-alice-Documents-Acme-acme-hub",
        "-Users-alice-Documents-Personal-",
    ]
    let groups = ProjectGroup.groupDirectories(dirs)
    #expect(groups.count == 2) // Acme, Personal
    let acme = groups.first { $0.name == "Acme" }
    #expect(acme != nil)
    #expect(acme!.projectDirs.count == 2)
}

// MARK: - Worktrees and scratch folders

private let home = "/Users/dev"
private let internalDir = "\(home)/Documents/Internal - Dev"
/// A history mixing project folders with worktrees of them (no folder exists on disk).
private let historyCwds = [
    "\(internalDir)",
    "\(internalDir)/site",
    "\(internalDir)/site/docs",
    "\(home)/Documents/Acme/app",
    "\(home)/Documents/Acme/app/.claude/worktrees/feature-x",
    "\(home)/Documents/Acme/app/.worktrees/hotfix",
    "\(home)/Documents/Acme-worktrees/lig-t12",
    "\(home)/Documents/Acme",
    "\(home)/Library/Application Support/Horus/parallel-worktrees/site-d9470035/horus-conversa-0a1b2c3d-task",
    "\(home)/Library/Application Support/Horus/parallel-worktrees/gone-1234abcd/horus-conversa-9f8e7d6c-task",
    "/private/tmp/claude-501/-Users-dev-Documents-Acme-app/441215ec-fa16-4c61-9222-046e26d390cf/scratchpad/demo",
    "/srv/demo/site",
    "/srv/demo/.profile/parallel-worktrees/site-2ef4e616/horus-conversa-58e736ad-x",
    "/",
]

@Test func worktreesAndScratchFoldersJoinTheirProject() {
    let resolver = ProjectGroup.Resolver(cwds: historyCwds, gitWorktreeRoot: { _ in nil })
    let temporary = ProjectGroup.temporaryFoldersName
    let groups = Dictionary(uniqueKeysWithValues: historyCwds.map { ($0, resolver.groupName(forCwd: $0)) })

    // The parent folder and its subfolders are one group.
    #expect(groups["\(internalDir)"] == "Internal - Dev")
    #expect(groups["\(internalDir)/site/docs"] == "Internal - Dev")
    // Worktrees inside the repository and in a sibling "<repo>-worktrees" folder.
    #expect(groups["\(home)/Documents/Acme/app/.claude/worktrees/feature-x"] == "Acme")
    #expect(groups["\(home)/Documents/Acme/app/.worktrees/hotfix"] == "Acme")
    #expect(groups["\(home)/Documents/Acme-worktrees/lig-t12"] == "Acme")
    // Horus worktrees join the known folder with the repository's name...
    #expect(groups[historyCwds[8]] == "Internal - Dev")
    // ...the one closest to the worktree when two folders share the name...
    let demoOwner = resolver.owner(of: historyCwds[12])
    #expect(demoOwner == .path("/srv/demo/site"))
    // ...or are temporary when the repository is not in the history.
    #expect(groups[historyCwds[9]] == temporary)
    // A Claude Code scratchpad is a temporary folder.
    #expect(groups[historyCwds[10]] == temporary)
    #expect(resolver.owner(of: historyCwds[10]) == .temporary)
    // Sessions started at the filesystem root have no project.
    #expect(groups["/"] == "Unknown")
    // Project folders are not moved.
    #expect(resolver.owner(of: "\(home)/Documents/Acme/app") == nil)

    // Nothing is left grouped under a worktree's own folder name ("site" is /srv/demo/site,
    // named after its last folder like any project outside Documents).
    #expect(Set(groups.values) == ["Internal - Dev", "Acme", "site", "Unknown", temporary])
}

@Test func groupingDoesNotDependOnOrder() {
    var rng = SystemRandomNumberGenerator()
    let reference = ProjectGroup.Resolver(cwds: historyCwds, gitWorktreeRoot: { _ in nil })
    for _ in 0..<20 {
        let shuffled = historyCwds.shuffled(using: &rng)
        let resolver = ProjectGroup.Resolver(cwds: shuffled, gitWorktreeRoot: { _ in nil })
        for cwd in historyCwds {
            #expect(resolver.groupName(forCwd: cwd) == reference.groupName(forCwd: cwd))
        }
    }
}

@Test func gitWorktreeFileNamesTheMainCheckout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("thoth-wt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let main = root.appendingPathComponent("Documents/Acme/app")
    let worktree = root.appendingPathComponent("elsewhere/feature")
    let submodule = root.appendingPathComponent("Documents/Acme/app/vendor/lib")
    for dir in [main.appendingPathComponent(".git"), worktree, submodule] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    try Data("gitdir: \(main.path)/.git/worktrees/feature\n".utf8)
        .write(to: worktree.appendingPathComponent(".git"))
    try Data("gitdir: ../../.git/modules/lib\n".utf8).write(to: submodule.appendingPathComponent(".git"))

    #expect(ProjectGroup.Resolver.gitWorktreeRoot(of: worktree.path) == main.path)
    #expect(ProjectGroup.Resolver.gitWorktreeRoot(of: main.path) == nil) // .git is a directory
    #expect(ProjectGroup.Resolver.gitWorktreeRoot(of: submodule.path) == nil)
    #expect(ProjectGroup.Resolver.gitWorktreeRoot(of: root.appendingPathComponent("missing").path) == nil)

    // The folders are in the temporary directory: leave it out of the temporary roots here.
    let resolver = ProjectGroup.Resolver(cwds: [main.path, worktree.path], temporaryRoots: [])
    #expect(resolver.groupName(forCwd: worktree.path) == "Acme")
    // With the real roots, the same folders are temporary.
    #expect(ProjectGroup.Resolver(cwds: [main.path, worktree.path]).groupName(forCwd: worktree.path)
            == ProjectGroup.temporaryFoldersName)
}

// MARK: - Temporary folders

private let tempTMPDIR = (NSTemporaryDirectory() as NSString).standardizingPath
/// Synthetic folders that are temporary, in every place the picker used to list one by one.
private let temporaryCwds = [
    "/private/var/folders/xx/yy/T/snap-on-AbC123",
    "/private/var/folders/xx/yy/T/snap-off-XyZ789",
    "/var/folders/xx/yy/T/smoke-test-Q1w2E3",
    "/private/var/folders/xx/yy/T",
    "/tmp",
    "/tmp/smoke-run",
    "/private/tmp/scratch/site",
    "/private/tmp/claude-501/-Users-dev-Documents-Acme-app/441215ec-fa16-4c61-9222-046e26d390cf/scratchpad",
    "/private/tmp/claude-501/-Users-dev-Documents-Acme-app/441215ec-fa16-4c61-9222-046e26d390cf/scratchpad/demo",
    "/private/tmp/claude-501/-Users-dev-Documents-Acme-app/441215ec-fa16-4c61-9222-046e26d390cf/scratchpad/x/parallel-worktrees/demo-0a1b2c3d/horus-conversa-1",
    "/private/tmp/demo/.profile/parallel-worktrees/site-2ef4e616/horus-conversa-58e736ad-x",
    // A scratchpad outside /tmp (a TMPDIR set elsewhere).
    "/Volumes/Scratch/claude-501/-Users-dev-Documents-Acme-app/441215ec-fa16-4c61-9222-046e26d390cf/scratchpad",
    // Tool worktrees in Application Support whose repository can't be told.
    "\(home)/Library/Application Support/Horus/parallel-worktrees/snap-on-AbC123-1234abcd/horus-conversa-9f8e7d6c-task",
    "\(home)/Library/Application Support/Horus/parallel-worktrees/no-hex-suffix/task",
    "\(home)/Library/Application Support/SomeTool/workspaces/ws1/worktrees/feature-y",
    "\(home)/Library/Application Support/OtherTool/repo-worktrees/feature-z/src",
    tempTMPDIR + "/tool-smoke-Zx9Yw8",
]

@Test func temporaryFoldersAreOneGroup() {
    let cwds = historyCwds + temporaryCwds + ["/private/var/folders/xx/yy/T/repo-AbC123"]
    let resolver = ProjectGroup.Resolver(cwds: cwds, gitWorktreeRoot: { _ in nil })
    for cwd in temporaryCwds {
        #expect(resolver.groupName(forCwd: cwd) == ProjectGroup.temporaryFoldersName, "\(cwd)")
        #expect(resolver.owner(of: cwd) == .temporary, "\(cwd)")
    }
    // A Horus worktree of a temporary repository found in the history is temporary too.
    let ofTempRepo = "\(home)/Library/Application Support/Horus/parallel-worktrees/repo-AbC123-0f0f0f0f/task"
    #expect(resolver.owner(of: ofTempRepo) == .temporary)
    // Lookalikes are left alone.
    for cwd in ["/srv/tmp/app", "/Users/dev/tmp", "/private/tmpfoo/app", "/var/folderz/app",
                "\(home)/Documents/Acme/worktrees/app"] {
        #expect(resolver.owner(of: cwd) != .temporary, "\(cwd)")
    }
    // The project folders of the history are not moved.
    #expect(resolver.groupName(forCwd: "\(home)/Documents/Acme/app") == "Acme")
}

@Test func gitWorktreesFollowTheTemporaryRule() {
    let real = "/srv/dev/Documents/Acme/app"
    let tempRepo = "/private/var/folders/xx/yy/T/fixture-AbC123"
    let roots: [String: String] = [
        // A worktree in Application Support whose .git file names a real project: that project.
        "/Users/dev/Library/Application Support/Tool/worktrees/feature": real,
        // One whose repository is temporary: temporary.
        "/Users/dev/Library/Application Support/Tool/worktrees/other": tempRepo,
        // A worktree inside a temporary folder: temporary, whatever its repository.
        "/private/tmp/wt/feature": real,
    ]
    let resolver = ProjectGroup.Resolver(cwds: [real] + roots.keys, gitWorktreeRoot: { roots[$0] })
    #expect(resolver.groupName(forCwd: "/Users/dev/Library/Application Support/Tool/worktrees/feature") == "Acme")
    #expect(resolver.owner(of: "/Users/dev/Library/Application Support/Tool/worktrees/other") == .temporary)
    #expect(resolver.owner(of: "/private/tmp/wt/feature") == .temporary)
}

@Test func encodedTemporaryFolders() {
    for dir in ["-private-var-folders-xx-yy-T-snap-on-AbC123", "-var-folders-xx-yy-T-x", "-tmp", "-tmp-smoke-run",
                "-private-tmp-claude-501--Users-dev-Documents-Acme-app-441215ec-scratchpad"] {
        #expect(ProjectGroup.isTemporary(encodedDir: dir), "\(dir)")
    }
    for dir in ["-Users-dev-Documents-Acme-app", "-srv-tmp-app", "-private-tmpfoo"] {
        #expect(!ProjectGroup.isTemporary(encodedDir: dir), "\(dir)")
    }
}

@Test func menuOrderIsByCostWithTemporaryFoldersLast() {
    let order = ProjectGroup.menuOrder([
        "Beta": 3, ProjectGroup.temporaryFoldersName: 100, "alpha": 3, "Gamma": 50, "Delta": 0,
    ])
    #expect(order.map(\.name) == ["Gamma", "alpha", "Beta", "Delta", ProjectGroup.temporaryFoldersName])
    #expect(order.map(\.cost) == [50, 3, 3, 0, 100])
    #expect(ProjectGroup.menuOrder(["A": 1]).map(\.name) == ["A"])
    #expect(ProjectGroup.menuOrder([:]).isEmpty)
}

