// Sources/Thoth/Models/DataStatus.swift
import Foundation

/// Where the numbers on screen come from, so a real zero never looks like a failed read.
enum DataStatus: Equatable {
    /// First read of the history since launch; `filesRead` of `filesTotal` once known.
    case loading(filesRead: Int, filesTotal: Int)
    /// No `~/.claude/projects` folder: Claude Code hasn't written any history here.
    case noHistory
    /// The projects folder exists but can't be listed (permissions or an I/O error).
    case inaccessible(reason: String)
    /// Read, but `failedItems` of the transcripts (or folders) couldn't be read and are left out.
    case partial(failedItems: Int, totalFiles: Int)
    /// Every transcript was read; zeros are real zeros.
    case ready

    static let initial = DataStatus.loading(filesRead: 0, filesTotal: 0)

    /// True when the figures on screen come from a read of the history (possibly incomplete).
    /// When false they are placeholders and must not be shown as amounts.
    var showsFigures: Bool {
        switch self {
        case .ready, .partial: return true
        case .loading, .noHistory, .inaccessible: return false
        }
    }

    /// Outcome of a scan whose projects folder could be listed.
    static func afterScan(totalFiles: Int, failedItems: Int) -> DataStatus {
        failedItems > 0 ? .partial(failedItems: failedItems, totalFiles: totalFiles) : .ready
    }

    /// Short line for the popover; nil when everything was read (the footer's "Updated" is enough).
    var notice: String? {
        switch self {
        case let .loading(read, total):
            return total > 0 ? "Reading history… \(read) of \(total) files" : "Reading history…"
        case .noHistory:
            return "No Claude Code history found in ~/.claude/projects"
        case let .inaccessible(reason):
            return "Can't read ~/.claude/projects: \(reason)"
        case let .partial(failed, _):
            return failed == 1 ? "1 transcript couldn't be read and is left out"
                               : "\(failed) transcripts couldn't be read and are left out"
        case .ready:
            return nil
        }
    }

    /// Replaces the tabs' lists (periods, models, trends, projects) when there are no figures to
    /// show; nil when they come from a read, partial ones included (real, if incomplete).
    var unavailableMessage: String? {
        switch self {
        case .loading: return "Figures appear when the first read of the history finishes."
        case .noHistory: return "Nothing to show until Claude Code saves its first session."
        case .inaccessible: return "The history couldn't be read. Check the folder's permissions."
        case .partial, .ready: return nil
        }
    }

    /// Placeholder shown instead of an amount when `showsFigures` is false.
    static let placeholder = "—"

    /// `figure` when the history was read, the placeholder otherwise.
    func display(_ figure: String) -> String {
        showsFigures ? figure : Self.placeholder
    }

    // MARK: - Freshness

    /// "Updated just now", "Updated 4 min ago", "Updated 2 h ago", "Updated 3 d ago".
    static func updatedText(lastRead: Date?, now: Date) -> String {
        guard let lastRead else { return "Not read yet" }
        let seconds = max(0, now.timeIntervalSince(lastRead))
        switch seconds {
        case ..<60: return "Updated just now"
        case ..<3_600: return "Updated \(Int(seconds / 60)) min ago"
        case ..<86_400: return "Updated \(Int(seconds / 3_600)) h ago"
        default: return "Updated \(Int(seconds / 86_400)) d ago"
        }
    }

    // MARK: - Projects folder probe

    enum FolderProbe: Equatable {
        case missing
        case unreadable(reason: String)
        case listed([String])
    }

    /// Lists `path`, telling a missing folder from one that can't be read.
    static func probe(_ path: String) -> FolderProbe {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return .missing }
        guard isDir.boolValue else { return .unreadable(reason: "not a folder") }
        do {
            return .listed(try FileManager.default.contentsOfDirectory(atPath: path))
        } catch {
            return .unreadable(reason: reason(for: error))
        }
    }

    private static func reason(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileReadNoPermissionError { return "permission denied" }
        if let posix = ns.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain,
           posix.code == Int(EACCES) || posix.code == Int(EPERM) {
            return "permission denied"
        }
        return "read error"
    }
}
