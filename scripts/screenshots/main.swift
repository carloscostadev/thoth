// README screenshots: renders the real PopoverView over a synthetic history (no ~/.claude).
// Built and run by capture.sh. Usage: thoth-screenshots <light|dark> <output-dir>
import SwiftUI
import AppKit

let args = CommandLine.arguments
let isDark = args.count > 1 && args[1] == "dark"
let outDir = URL(fileURLWithPath: args.count > 2 ? args[2] : ".")

// Synthetic projects only: the folder after Documents/ is the project group shown.
var history = try! SyntheticHistory(models: [
    "claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1",
], seed: 7)
try! history.generate(projects: 6, filesPerProject: 8, messagesPerFile: 30, todayShare: 0.08, cwds: [
    "/srv/synthetic/Documents/Acme/web",
    "/srv/synthetic/Documents/Acme/api",
    "/srv/synthetic/Documents/Globex/app",
    "/srv/synthetic/Documents/Initech/reports",
    "/srv/synthetic/Documents/Side Projects/notes",
    "/srv/synthetic/Documents/Globex/infra",
])

// The generator dates past sessions at the current time of day; move each one to a working
// hour of its own day so the heatmap looks like a real week.
var rng = SplitMix64(seed: 11)
let hours = [9, 9, 10, 10, 11, 11, 12, 14, 14, 15, 15, 16, 16, 17, 18, 21]
let today = Calendar.current.startOfDay(for: Date())
for file in history.files where file.lastDate < today {
    var text = try! String(contentsOf: file.url, encoding: .utf8)
    let first = text.range(of: #""timestamp":""#)!.upperBound
    let start = ISO8601DateFormatter.withFractions.date(from: String(text[first...].prefix(24)))!
    let target = Calendar.current.startOfDay(for: start)
        .addingTimeInterval(Double(hours[rng.next(upTo: hours.count)] * 3600 + rng.next(upTo: 3000)))
    let shift = target.timeIntervalSince(start)
    var last = start
    text = text.replacing(#/"timestamp":"([^"]+)"/#) { match in
        last = ISO8601DateFormatter.withFractions.date(from: String(match.1))!.addingTimeInterval(shift)
        return #""timestamp":"\#(SyntheticHistory.timestamp(last))""#
    }
    try! text.write(to: file.url, atomically: true, encoding: .utf8)
    try! FileManager.default.setAttributes([.modificationDate: last], ofItemAtPath: file.url.path)
}

extension ISO8601DateFormatter {
    static let withFractions: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

// Two open sessions (Acme/web and Globex/app) that keep answering while the shots are taken.
let liveFiles = [0, 16]
for index in liveFiles { try! history.writeSession(forFileAt: index) }

let service = ClaudeDataService(claudeDir: history.root.path, defaults: nil)

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)!
app.appearance = appearance

let host = NSHostingView(rootView: PopoverView(service: service))
// Captured on its own with `screencapture -l` (the window's pixels only, never the rest of the
// display), on a Retina screen for 2x.
guard let screen = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) else {
    fatalError("needs a Retina display for 2x captures")
}
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 800),
                      styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = appearance
window.hasShadow = false
window.contentView = host
func place() {
    window.setContentSize(host.fittingSize)
    window.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.minX + 40, y: screen.visibleFrame.maxY - 40))
}
place()
window.orderFrontRegardless()

/// Clicks a tab. The tab bar is the row under the header card and its three tabs share its
/// width equally: index 0 Overview, 1 Trends, 2 Projects.
func clickTab(_ index: Int) {
    let barTop: CGFloat = 244, inset = Theme.Spacing.lg
    let width = host.bounds.width - inset * 2
    let p = NSPoint(x: inset + width * (CGFloat(index) + 0.5) / 3, y: host.bounds.height - barTop)
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
        window.sendEvent(NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
    }
}

/// One small response in an open session, so the header shows a moderate live burn rate.
func appendLiveResponse(to index: Int) {
    let file = history.files[index]
    let ts = SyntheticHistory.timestamp(Date())
    let id = "msg_live_\(UUID().uuidString.prefix(8))"
    let line = #"{"type":"assistant","cwd":"\#(file.cwd)","requestId":"req_\#(id)","timestamp":"\#(ts)","message":{"id":"\#(id)","model":"claude-opus-5-5","role":"assistant","content":[{"type":"tool_use","id":"toolu_\#(id)","name":"Edit","input":{}}],"stop_reason":null,"usage":{"input_tokens":6,"cache_creation_input_tokens":80,"cache_read_input_tokens":300,"output_tokens":180}}}"#
    let handle = try! FileHandle(forWritingTo: file.url)
    try! handle.seekToEnd()
    try! handle.write(contentsOf: Data((line + "\n").utf8))
    try! handle.close()
}

/// Captures the popover window at 2x and frames it with rounded corners, a hairline border and
/// a soft shadow on a transparent canvas.
func capture(_ name: String) {
    place()
    let raw = FileManager.default.temporaryDirectory.appendingPathComponent("thoth-window-\(UUID().uuidString).png")
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
    task.arguments = ["-x", "-o", "-l\(window.windowNumber)", raw.path]
    try! task.run()
    task.waitUntilExit()
    let rep = NSBitmapImageRep(data: try! Data(contentsOf: raw))!
    try? FileManager.default.removeItem(at: raw)
    let size = window.frame.size, scale: CGFloat = 2, margin: CGFloat = 24, radius: CGFloat = 14
    precondition(rep.pixelsWide == Int(size.width * scale), "not a 2x capture")
    let popover = NSImage(size: size)
    popover.addRepresentation(rep)

    let canvas = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
    let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * scale), pixelsHigh: Int(canvas.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    out.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
    let rect = NSRect(x: margin, y: margin, width: size.width, height: size.height)
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(isDark ? 0.45 : 0.16)
    shadow.shadowBlurRadius = 16
    shadow.shadowOffset = NSSize(width: 0, height: -4)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    popover.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.12 : 0.10).setStroke()
    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: radius, yRadius: radius)
    border.lineWidth = 0.5
    border.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try! out.representation(using: .png, properties: [:])!.write(to: outDir.appendingPathComponent(name + ".png"))
    print("wrote \(name).png")
}

/// Runs `steps` one after another; each waits its own delay (seconds) first.
func run(_ steps: [(Double, () -> Void)]) {
    guard let (delay, step) = steps.first else { return }
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        step()
        run(Array(steps.dropFirst()))
    }
}

service.start()
Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
    for index in liveFiles { appendLiveResponse(to: index) }
}
// The burn rate needs a few polls (every 5 s), also after the filter resets it.
run([
    (16, { capture("overview") }),
    (1, { clickTab(1) }), (1, { capture("trends") }),
    (1, { clickTab(2) }), (1, { capture("projects") }),
    (1, { clickTab(0) }), (1, { service.applyFilter("Globex") }), (12, { capture("overview-globex") }),
    (0, {
        history.remove()
        exit(0)
    }),
])
app.run()
