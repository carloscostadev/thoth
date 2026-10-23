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
    "/private/tmp/demo/site",
    "/private/tmp/demo/.profile/parallel-worktrees/site-2ef4e616/horus-conversa-58e736ad-x",
    "/",
]

@Test func worktreesAndScratchFoldersJoinTheirProject() {
    let resolver = ProjectGroup.Resolver(cwds: historyCwds, gitWorktreeRoot: { _ in nil })
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
    #expect(demoOwner == .path("/private/tmp/demo/site"))
    // ...or are named after the repository when it is not in the history.
    #expect(groups[historyCwds[9]] == "gone")
    // A Claude Code scratchpad belongs to the project whose session created it.
    #expect(groups[historyCwds[10]] == "Acme")
    #expect(resolver.owner(of: historyCwds[10]) == .path("\(home)/Documents/Acme/app"))
    // Sessions started at the filesystem root have no project.
    #expect(groups["/"] == "Unknown")
    // Project folders are not moved.
    #expect(resolver.owner(of: "\(home)/Documents/Acme/app") == nil)

    // Nothing is left grouped under a worktree's own folder name ("site" is /private/tmp/demo/site,
    // named after its last folder like any project outside Documents).
    #expect(Set(groups.values) == ["Internal - Dev", "Acme", "gone", "site", "Unknown"])
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

    let resolver = ProjectGroup.Resolver(cwds: [main.path, worktree.path])
    #expect(resolver.groupName(forCwd: worktree.path) == "Acme")
}
