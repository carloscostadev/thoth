// Tests/ThothTests/Support/SyntheticHistory.swift
import Foundation

/// Deterministic generator for a fake `~/.claude` tree in a temporary directory.
///
/// The layout and line shapes mirror what Claude Code writes: one JSONL per session under
/// `projects/<encoded-cwd>/`, a user line followed by one assistant line per content block
/// (thinking / text / tool_use), and every assistant line of the same API response repeating
/// the same `message.id` and `usage`, with `output_tokens` growing while the response streams:
/// only the last line carries the final count. No real user data is involved.
struct SyntheticHistory {
    /// One unique API response, as it should be counted.
    struct Request {
        let model: String
        let input: Int
        let output: Int
        let cacheWrite5m: Int
        let cacheWrite1h: Int
        let cacheRead: Int
        let date: Date
        let tools: [String]

        var cacheWrite: Int { cacheWrite5m + cacheWrite1h }
        var totalTokens: Int { input + output + cacheWrite + cacheRead }
    }

    struct File {
        let url: URL
        let cwd: String
        var lastDate: Date
        var messageCounter: Int
    }

    let root: URL
    private(set) var requests: [Request] = []
    private(set) var files: [File] = []
    private(set) var bytesWritten: Int = 0
    private var rng: SplitMix64
    private let models: [String]

    var projectsDir: URL { root.appendingPathComponent("projects") }

    init(models: [String], seed: UInt64 = 42) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("thoth-synthetic-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"),
                                                withIntermediateDirectories: true)
        rng = SplitMix64(seed: seed)
        self.models = models
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Claude Code's directory encoding: every non-alphanumeric character becomes "-".
    static func encode(cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Creates `projects × filesPerProject` session files with `messagesPerFile` responses each.
    /// `todayShare` of the files hold today's activity; the rest are spread over the last 60 days.
    /// `cwds`, when given, names each project's working directory instead.
    mutating func generate(projects: Int, filesPerProject: Int, messagesPerFile: Int,
                           todayShare: Double = 0.1, cwdBase: String = "/srv/synthetic/Documents",
                           cwds: [String]? = nil) throws {
        let now = Date()
        for p in 0..<projects {
            let cwd = cwds?[p] ?? "\(cwdBase)/Group\(p % 5)/project-\(p)"
            let dir = projectsDir.appendingPathComponent(Self.encode(cwd: cwd))
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<filesPerProject {
                let url = dir.appendingPathComponent("session-\(p)-\(f).jsonl")
                let isToday = rng.nextDouble() < todayShare
                let span = Double(messagesPerFile) * 20
                let start: Date
                if isToday {
                    let midnight = Calendar.current.startOfDay(for: now)
                    start = max(midnight.addingTimeInterval(1), now.addingTimeInterval(-span - 60))
                } else {
                    let daysAgo = Double(1 + rng.next(upTo: 59))
                    start = now.addingTimeInterval(-daysAgo * 86_400 - span)
                }
                var file = File(url: url, cwd: cwd, lastDate: start, messageCounter: 0)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                try write(messages: messagesPerFile, to: &file)
                files.append(file)
            }
        }
    }

    /// Appends `messages` new responses to the first `fileCount` files (incremental scan scenario).
    mutating func append(messages: Int, toFiles fileCount: Int) throws {
        for i in 0..<min(fileCount, files.count) {
            var file = files[i]
            file.lastDate = max(file.lastDate, Date().addingTimeInterval(-Double(messages) * 20))
            try write(messages: messages, to: &file)
            files[i] = file
        }
    }

    /// Writes a session heartbeat for `files[index]` owned by the current (alive) process.
    func writeSession(forFileAt index: Int) throws {
        let file = files[index]
        let sessionId = file.url.deletingPathExtension().lastPathComponent
        let json: [String: Any] = [
            "pid": Int(getpid()), "sessionId": sessionId, "cwd": file.cwd,
            "startedAt": Int64(Date().timeIntervalSince1970 * 1000),
            "kind": "interactive", "entrypoint": "cli",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        try data.write(to: root.appendingPathComponent("sessions/\(sessionId).json"))
    }

    // MARK: - Line generation

    private mutating func write(messages: Int, to file: inout File) throws {
        var out = ""
        out.reserveCapacity(messages * 4_000)
        for _ in 0..<messages {
            file.lastDate = file.lastDate.addingTimeInterval(Double(10 + rng.next(upTo: 20)))
            file.messageCounter += 1
            let request = makeRequest(date: file.lastDate)
            requests.append(request)
            let ts = Self.timestamp(request.date)
            let msgId = "msg_" + String(rng.next(), radix: 16)

            out += #"{"type":"user","cwd":"\#(file.cwd)","timestamp":"\#(ts)","message":{"role":"user","content":[{"type":"tool_result","content":"\#(filler(600 + rng.next(upTo: 1_800)))"}]}}"#
            out += "\n"

            func usage(output: Int) -> String {
                #"{"input_tokens":\#(request.input),"cache_creation_input_tokens":\#(request.cacheWrite),"cache_read_input_tokens":\#(request.cacheRead),"cache_creation":{"ephemeral_5m_input_tokens":\#(request.cacheWrite5m),"ephemeral_1h_input_tokens":\#(request.cacheWrite1h)},"output_tokens":\#(output),"service_tier":"standard"}"#
            }
            var blocks: [String] = [#"{"type":"thinking","thinking":"","signature":"\#(filler(300 + rng.next(upTo: 900)))"}"#]
            if rng.nextDouble() < 0.5 {
                blocks.append(#"{"type":"text","text":"\#(filler(100 + rng.next(upTo: 600)))"}"#)
            }
            for tool in request.tools {
                blocks.append(#"{"type":"tool_use","id":"toolu_\#(rng.next(upTo: 1_000_000))","name":"\#(tool)","input":{"command":"\#(filler(40 + rng.next(upTo: 200)))"}}"#)
            }
            for (k, block) in blocks.enumerated() {
                // Partial output on earlier lines, the final count on the last one.
                let output = k == blocks.count - 1
                    ? request.output : max(1, request.output * (k + 1) / (blocks.count + 1))
                out += #"{"type":"assistant","cwd":"\#(file.cwd)","requestId":"req_\#(msgId)","timestamp":"\#(ts)","message":{"id":"\#(msgId)","model":"\#(request.model)","role":"assistant","content":[\#(block)],"stop_reason":null,"usage":\#(usage(output: output))}}"#
                out += "\n"
            }
        }
        let data = Data(out.utf8)
        let handle = try FileHandle(forWritingTo: file.url)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: file.lastDate], ofItemAtPath: file.url.path)
        bytesWritten += data.count
    }

    private mutating func makeRequest(date: Date) -> Request {
        let model = models[rng.next(upTo: models.count)]
        let cacheWrite = rng.next(upTo: 8_000)
        let oneHour = rng.nextDouble() < 0.8
        let toolPool = ["Edit", "Read", "Bash", "Grep", "TodoWrite", "WebFetch"]
        let toolCount = rng.next(upTo: 3)
        let tools = (0..<toolCount).map { _ in toolPool[rng.next(upTo: toolPool.count)] }
        return Request(
            model: model,
            input: 1 + rng.next(upTo: 50),
            output: 20 + rng.next(upTo: 2_000),
            cacheWrite5m: oneHour ? 0 : cacheWrite,
            cacheWrite1h: oneHour ? cacheWrite : 0,
            cacheRead: rng.next(upTo: 150_000),
            date: date,
            tools: tools
        )
    }

    private static let lorem = Array("lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore et dolore magna aliqua ".utf8)

    private mutating func filler(_ length: Int) -> String {
        let offset = rng.next(upTo: Self.lorem.count)
        var bytes = [UInt8]()
        bytes.reserveCapacity(length)
        for i in 0..<length { bytes.append(Self.lorem[(offset + i) % Self.lorem.count]) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func timestamp(_ date: Date) -> String { isoFormatter.string(from: date) }
}

/// Small deterministic PRNG so synthetic histories are reproducible across runs.
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(upTo bound: Int) -> Int { Int(next() % UInt64(max(bound, 1))) }
    mutating func nextDouble() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
