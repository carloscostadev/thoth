import Foundation

enum LaunchAtLogin {
    // Per-bundle label, so a side-by-side build ("Thoth Design") never replaces the
    // stable app's login item.
    private static let label = Bundle.main.bundleIdentifier ?? "com.carloscosta.thoth"
    private static let plistName = label + ".plist"

    private static var plistPath: String {
        let home = NSHomeDirectory()
        return home + "/Library/LaunchAgents/" + plistName
    }

    private static var appPath: String {
        Bundle.main.bundlePath
    }

    static var isEnabled: Bool {
        get {
            FileManager.default.fileExists(atPath: plistPath)
        }
        set {
            if newValue {
                install()
            } else {
                uninstall()
            }
        }
    }

    private static func install() {
        let launchAgentsDir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: launchAgentsDir, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [appPath + "/Contents/MacOS/Thoth"],
            "RunAtLoad": true,
            "KeepAlive": false,
        ]

        let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        FileManager.default.createFile(atPath: plistPath, contents: data)
    }

    private static func uninstall() {
        try? FileManager.default.removeItem(atPath: plistPath)
    }
}
