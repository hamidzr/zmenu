import AppKit
import ApplicationServices
import Darwin

// Measure observed OS focus and real keyboard delivery from an external launch trigger.
struct Options {
    var binary = ""
    var runs = 3
    var delays: [Double] = [25, 50, 75, 100, 150, 200, 300]
    var count = 2000
    var mode = "classic"
    var stdinDelayMs = 0.0
    var ready = false
    var profile = false
    var accept = false
    var ipcItems = false
    var showIcons = false
    var ctl = ""
    var prefill = false
    var recordDir = ""
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

let help = """
Usage: startup_bench.sh [options]
  --binary PATH          zmenu executable (default: zig-out/bin/zmenu)
  --runs N               trials per delay (default: 3)
  --delays MS,MS,...      first-key offsets from launch (default: 25,50,75,100,150,200,300)
  --count N              synthetic stdin item count (default: 2000)
  --mode classic|follow|ipc  input source (default: classic)
  --stdin-delay-ms MS     delay writing stdin from launch (default: 0)
  --ready                type immediately after observed focused text editor
  --accept               press Return and verify synthetic stdout selection
  --ipc-items            populate IPC items during launch via zmenuctl
  --show-icons           include the icon column used by combo-switcher
  --ctl PATH             zmenuctl executable (default: sibling of --binary)
  --profile              capture zmenu --startup-profile phase timings
  --prefill              start with synthetic stale query; verify typing replaces it
  --record-dir PATH      record 3-second menu-region videos over an owned backdrop
                         uses default numeric selection; timings include recorder overhead
  --help                 show help without opening windows or checking permissions

Types qwerty with 10 ms between keys. Requires existing Accessibility and event-posting
permissions; never requests permissions. Uses an owned sink for keys before zmenu
focus. Aborts if another app becomes foreground. Restores original app afterward.
Stdout: JSONL trials and summaries. Stderr: concise timing/loss summaries.
Timing uses external pre-Process.run monotonic trigger; focus/input times are observed
with polling and include AX overhead. This measures warm OS launches, not cache eviction.
"""

func parseOptions() throws -> Options {
    var options = Options()
    let args = Array(CommandLine.arguments.dropFirst())
    var index = 0
    while index < args.count {
        let flag = args[index]
        if flag == "--help" || flag == "-h" { print(help); exit(0) }
        if flag == "--ready" { options.ready = true; index += 1; continue }
        if flag == "--accept" { options.accept = true; index += 1; continue }
        if flag == "--ipc-items" { options.ipcItems = true; index += 1; continue }
        if flag == "--show-icons" { options.showIcons = true; index += 1; continue }
        if flag == "--profile" { options.profile = true; index += 1; continue }
        if flag == "--prefill" { options.prefill = true; index += 1; continue }
        guard index + 1 < args.count else { throw BenchError("missing value for \(flag)") }
        let value = args[index + 1]
        switch flag {
        case "--binary": options.binary = value
        case "--ctl": options.ctl = value
        case "--record-dir":
            guard !value.isEmpty else { throw BenchError("--record-dir requires a path") }
            options.recordDir = value
        case "--runs":
            guard let number = Int(value), number > 0 else { throw BenchError("--runs must be positive") }
            options.runs = number
        case "--delays":
            let values = value.split(separator: ",", omittingEmptySubsequences: false).compactMap { Double($0) }
            guard values.count == value.split(separator: ",", omittingEmptySubsequences: false).count,
                  !values.isEmpty, values.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10000 }) else {
                throw BenchError("--delays must contain milliseconds between 0 and 10000")
            }
            options.delays = values
        case "--count":
            guard let number = Int(value), number > 0, number <= 100000 else { throw BenchError("--count must be 1...100000") }
            options.count = number
        case "--mode":
            guard ["classic", "follow", "ipc"].contains(value) else { throw BenchError("unknown --mode") }
            options.mode = value
        case "--stdin-delay-ms":
            guard let number = Double(value), number.isFinite, number >= 0, number <= 10000 else {
                throw BenchError("--stdin-delay-ms must be 0...10000")
            }
            options.stdinDelayMs = number
        default: throw BenchError("unknown argument \(flag)")
        }
        index += 2
    }
    guard !options.binary.isEmpty, FileManager.default.isExecutableFile(atPath: options.binary) else {
        throw BenchError("missing executable; build zmenu or pass --binary PATH")
    }
    guard !options.ipcItems || options.mode == "ipc" else {
        throw BenchError("--ipc-items requires --mode ipc")
    }
    if options.mode == "ipc" && (options.accept || options.ipcItems) {
        if options.ctl.isEmpty {
            options.ctl = URL(fileURLWithPath: options.binary).deletingLastPathComponent()
                .appendingPathComponent("zmenuctl").path
        }
        guard FileManager.default.isExecutableFile(atPath: options.ctl) else {
            throw BenchError("missing zmenuctl executable; pass --ctl PATH")
        }
        guard options.count <= 10000 else {
            throw BenchError("IPC item trials support --count <= 10000 to stay within protocol payload limit")
        }
    }
    return options
}

// match Zig's .awake clock so child profile stages align with the external trigger
func nowNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func elapsedMs(_ start: UInt64) -> Double { Double(nowNs() - start) / 1_000_000 }
func deadline(_ start: UInt64, _ milliseconds: Double) -> UInt64 {
    start + UInt64(milliseconds * 1_000_000)
}
func stderr(_ value: String) { FileHandle.standardError.write(Data((value + "\n").utf8)) }
func jsonLine(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func pumpEvents() {
    if let event = NSApp.nextEvent(matching: .any, until: Date(timeIntervalSinceNow: 0.001), inMode: .default, dequeue: true) {
        NSApp.sendEvent(event)
    }
    NSApp.updateWindows()
}

func axAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func focusedQuery(_ system: AXUIElement, childPid: pid_t) -> String? {
    guard let value = axAttribute(system, kAXFocusedUIElementAttribute),
          CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    let element = unsafeBitCast(value, to: AXUIElement.self)
    var focusedPid: pid_t = 0
    guard AXUIElementGetPid(element, &focusedPid) == .success, focusedPid == childPid else { return nil }
    AXUIElementSetMessagingTimeout(element, 0.003)
    guard let role = axAttribute(element, kAXRoleAttribute) as? String,
          [kAXTextFieldRole, kAXTextAreaRole, "AXSearchField"].contains(role) else { return nil }
    return axAttribute(element, kAXValueAttribute) as? String
}

// Check header count and the first table row without walking every result row.
func itemsVisible(_ application: AXUIElement, count: Int) -> Bool {
    var pending = axAttribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
    var cursor = 0
    var firstRow = false
    var fullCount = false
    while cursor < pending.count && cursor < 256 {
        let element = pending[cursor]
        cursor += 1
        AXUIElementSetMessagingTimeout(element, 0.003)
        if let value = axAttribute(element, kAXValueAttribute) as? String {
            if value == "qwerty-match-0" { firstRow = true }
            if value == "\(count) / \(count)" { fullCount = true }
        }
        if firstRow && fullCount { return true }
        if axAttribute(element, kAXRoleAttribute) as? String == kAXTableRole {
            var rowCount = 0
            var rows: CFArray?
            if AXUIElementGetAttributeValueCount(element, kAXRowsAttribute as CFString, &rowCount) == .success,
               rowCount > 0,
               AXUIElementCopyAttributeValues(element, kAXRowsAttribute as CFString, 0, 1, &rows) == .success,
               let first = (rows as? [AXUIElement])?.first {
                pending.append(first)
            }
            // AXChildren also exposes columns and thousands of offscreen cells.
            continue
        }
        if let children = axAttribute(element, kAXChildrenAttribute) as? [AXUIElement] {
            pending.append(contentsOf: children.prefix(32))
        }
    }
    return false
}

func postReturn() throws {
    for pressed in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: pressed) else {
            throw BenchError("cannot create Return event")
        }
        event.flags = []
        event.post(tap: .cghidEventTap)
    }
}

func validSelectionOutput(_ data: Data, ipc: Bool) -> Bool {
    if !ipc { return data == Data("qwerty-match-0\n".utf8) }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["id"] as? String == "qwerty-match-0",
          object["label"] as? String == "qwerty-match-0",
          Set(object.keys).isSubset(of: ["id", "label", "icon"]) else { return false }
    return object["icon"] == nil || object["icon"] is NSNull
}

func postCharacter(_ character: Character) throws {
    let units = Array(String(character).utf16)
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
        throw BenchError("cannot create keyboard event")
    }
    down.flags = []
    up.flags = []
    units.withUnsafeBufferPointer { pointer in
        down.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress)
        up.keyboardSetUnicodeString(stringLength: pointer.count, unicodeString: pointer.baseAddress)
    }
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
}

func stopChild(_ process: Process) {
    guard process.isRunning else { return }
    for pressed in [true, false] {
        CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: pressed)?.postToPid(process.processIdentifier)
    }
    let stop = deadline(nowNs(), 300)
    while process.isRunning && nowNs() < stop { pumpEvents() }
    if process.isRunning {
        process.terminate()
        let stop = deadline(nowNs(), 1000)
        while process.isRunning && nowNs() < stop { pumpEvents() }
    }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}

final class ActivationObservation {
    var start: UInt64 = 0
    var childPid: pid_t = 0
    var foregroundMs: Double?
}

final class Harness {
    let options: Options
    let app: NSApplication
    let window: NSWindow
    let sink: NSTextField
    let originalApp: NSRunningApplication?
    let ownPid = ProcessInfo.processInfo.processIdentifier
    let expected = "qwerty"

    init(_ options: Options) {
        self.options = options
        originalApp = NSWorkspace.shared.frontmostApplication
        app = NSApplication.shared
        app.setActivationPolicy(.regular)
        window = NSWindow(contentRect: options.recordDir.isEmpty ? NSRect(x: 100, y: 100, width: 420, height: 90) : NSScreen.main!.frame,
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "zmenu startup benchmark keyboard sink"
        window.isReleasedWhenClosed = false
        if !options.recordDir.isEmpty {
            window.backgroundColor = NSColor(calibratedWhite: 0.75, alpha: 1)
            window.hasShadow = false
        }
        sink = NSTextField(frame: NSRect(x: 16, y: 28, width: 388, height: 24))
        sink.placeholderString = "Early benchmark keys land here"
        window.contentView?.addSubview(sink)
        app.finishLaunching()
    }

    func restore() {
        window.orderOut(nil)
        originalApp?.activate(options: [])
        let stop = deadline(nowNs(), 300)
        while nowNs() < stop {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == originalApp?.processIdentifier { break }
            pumpEvents()
        }
    }

    func activateSink() throws {
        sink.stringValue = ""
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        window.makeFirstResponder(sink)
        let stop = deadline(nowNs(), 2000)
        while nowNs() < stop {
            pumpEvents()
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ownPid,
               window.isKeyWindow, sink.currentEditor() != nil { return }
        }
        throw BenchError("owned keyboard sink did not become active and focused")
    }

    func checkForeground(_ childPid: pid_t) throws -> pid_t {
        guard let foreground = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            throw BenchError("foreground app unavailable; no keys sent")
        }
        guard foreground == ownPid || foreground == childPid else {
            throw BenchError("unrelated app became foreground; keyboard trial aborted")
        }
        return foreground
    }

    func trial(_ number: Int, delayMs: Double) throws -> [String: Any] {
        try activateSink()
        var recorder: Process?
        var recordingPath: String?
        if !options.recordDir.isEmpty {
            try FileManager.default.createDirectory(atPath: options.recordDir, withIntermediateDirectories: true)
            let screen = NSScreen.main!.frame
            let width = min(1100, Int(screen.width) - 40)
            let height = min(800, Int(screen.height) - 120)
            let rect = "\(Int((screen.width - Double(width)) / 2)),\(Int((screen.height - Double(height)) / 2)),\(width),\(height)"
            let path = URL(fileURLWithPath: options.recordDir).appendingPathComponent("trial-\(number).mov").path
            guard !FileManager.default.fileExists(atPath: path) else { throw BenchError("recording already exists: \(path)") }
            let command = Process()
            command.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            command.arguments = ["-x", "-v", "-V3", "-R" + rect, path]
            command.standardOutput = FileHandle.nullDevice
            command.standardError = FileHandle.nullDevice
            try command.run()
            recorder = command
            recordingPath = path
            let settle = deadline(nowNs(), 500)
            while nowNs() < settle { pumpEvents() }
        }
        defer {
            if let recorder, recorder.isRunning {
                recorder.terminate()
                recorder.waitUntilExit()
            }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: options.binary)
        let menuId = "startup-bench-\(ownPid)-\(number)"
        process.arguments = ["--menu-id", menuId, "--title", menuId,
                             "--no-levenshtein-fallback", "--initial-query", options.prefill ? "stale" : "", "--limit", "0"]
        if options.recordDir.isEmpty { process.arguments?.append("--no-numeric-selection") }
        if options.profile { process.arguments?.append("--startup-profile") }
        if options.showIcons { process.arguments?.append("--show-icons") }
        if options.mode == "follow" { process.arguments?.append("--follow-stdin") }
        if options.mode == "ipc" { process.arguments?.append("--ipc-only") }
        var environment = ProcessInfo.processInfo.environment
        environment["GMENU_AUTO_ACCEPT"] = "false"
        environment["GMENU_TERMINAL_MODE"] = "false"
        environment["GMENU_FOLLOW_STDIN"] = options.mode == "follow" ? "true" : "false"
        environment["GMENU_IPC_ONLY"] = options.mode == "ipc" ? "true" : "false"
        process.environment = environment
        let outputPipe = Pipe()
        process.standardOutput = options.accept ? outputPipe : FileHandle.nullDevice
        let profilePipe = Pipe()
        process.standardError = options.profile ? profilePipe : FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = options.mode == "ipc" ? FileHandle.nullDevice : input
        let data = Data((0..<options.count).map { "qwerty-match-\($0)\n" }.joined().utf8)

        let activation = ActivationObservation()
        var focusedMs: Double?
        var acceptedMs: Double?
        var query: String?
        var sentMs: [Double] = []
        var latenessMs: [Double] = []
        let observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { notification in
            if let active = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               active.processIdentifier == activation.childPid, activation.start != 0, activation.foregroundMs == nil {
                activation.foregroundMs = elapsedMs(activation.start)
            }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        let start = nowNs()
        activation.start = start
        try process.run()
        let spawnReturnMs = elapsedMs(start)
        let childPid = process.processIdentifier
        activation.childPid = childPid
        defer { stopChild(process) }
        if options.profile { try profilePipe.fileHandleForWriting.close() }
        if options.accept { try outputPipe.fileHandleForWriting.close() }
        if options.mode != "ipc" {
            let writer = input.fileHandleForWriting
            DispatchQueue.global().asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline(start, options.stdinDelayMs))) {
                defer { try? writer.close() }
                try? writer.write(contentsOf: data)
            }
        }
        let focusedAX = AXUIElementCreateSystemWide()
        // Bound individual AX calls so an unresponsive child cannot stall the harness.
        AXUIElementSetMessagingTimeout(focusedAX, 0.003)
        let stop = deadline(start, max(5000, options.stdinDelayMs + 3000, delayMs + 3000))
        var nextKey = 0
        var firstKeyNs: UInt64?
        var lastQueryPoll: UInt64 = 0
        let characters = Array(expected)
        var postflightUntil: UInt64?
        let populateIPC = options.mode == "ipc" && (options.accept || options.ipcItems)
        let tempDir = environment["TMPDIR"] ?? environment["TMP"] ?? environment["TEMP"] ?? "/tmp"
        let socket = URL(fileURLWithPath: tempDir, isDirectory: true)
            .appendingPathComponent("zmenu.\(menuId).sock").path
        var controller: Process?
        var ipcSentMs: Double?
        var ipcAppliedMs: Double?
        defer {
            if let controller, controller.isRunning {
                controller.terminate()
                let stop = deadline(nowNs(), 300)
                while controller.isRunning && nowNs() < stop { pumpEvents() }
                if controller.isRunning { kill(controller.processIdentifier, SIGKILL) }
                controller.waitUntilExit()
            }
        }
        while nowNs() < stop {
            let foreground = try checkForeground(childPid)
            let time = nowNs()
            if firstKeyNs == nil {
                if options.ready {
                    if focusedMs != nil { firstKeyNs = nowNs() }
                } else {
                    firstKeyNs = deadline(start, delayMs)
                }
            }
            if let first = firstKeyNs, nextKey < characters.count,
               nowNs() >= first {
                // Check again immediately before every global key; never type into another app.
                _ = try checkForeground(childPid)
                latenessMs.append(Double(nowNs() - first) / 1_000_000)
                sentMs.append(elapsedMs(start))
                try postCharacter(characters[nextKey])
                nextKey += 1
                firstKeyNs = deadline(nowNs(), 10)
                if nextKey == characters.count { postflightUntil = deadline(nowNs(), 500) }
            }
            if foreground == childPid, activation.foregroundMs == nil {
                activation.foregroundMs = elapsedMs(start)
            }
            // Nonactivating panels can own keyboard focus while the sink app stays active.
            // Fixed-offset trials defer all AX polling until typing finishes to avoid shifting key delivery.
            if options.ready || nextKey == characters.count {
                if time - lastQueryPoll >= 1_000_000 {
                    lastQueryPoll = time
                    if let value = focusedQuery(focusedAX, childPid: childPid) {
                        query = value
                        if focusedMs == nil { focusedMs = elapsedMs(start) }
                        if !value.isEmpty && acceptedMs == nil { acceptedMs = elapsedMs(start) }
                    }
                }
            }
            if populateIPC && controller == nil && FileManager.default.fileExists(atPath: socket) {
                let command = Process()
                command.executableURL = URL(fileURLWithPath: options.ctl)
                command.arguments = ["--menu-id", menuId, "set", "--stdin"]
                command.environment = environment
                command.standardOutput = FileHandle.nullDevice
                command.standardError = FileHandle.nullDevice
                let pipe = Pipe()
                command.standardInput = pipe
                try command.run()
                controller = command
                ipcSentMs = elapsedMs(start)
                let writer = pipe.fileHandleForWriting
                DispatchQueue.global().async {
                    defer { try? writer.close() }
                    try? writer.write(contentsOf: data)
                }
            }
            if nextKey == characters.count, let until = postflightUntil,
               (query == expected || (focusedMs != nil && nowNs() >= until)) { break }
            if !process.isRunning { break }
            pumpEvents()
        }
        let sinkPrefix = sink.currentEditor()?.string ?? sink.stringValue
        guard expected.hasPrefix(sinkPrefix), query == nil || expected.hasSuffix(query!) else {
            throw BenchError("unexpected text in benchmark window; trial aborted without logging text")
        }
        let complete = query == expected
        let received = query?.count ?? 0
        var acceptSuccess = false
        var returnMs: Double?
        if options.accept || populateIPC {
            let applicationAX = AXUIElementCreateApplication(childPid)
            AXUIElementSetMessagingTimeout(applicationAX, 0.003)
            let updatesDeadline = deadline(nowNs(), 2000)
            var visible = false
            var lastItemPoll: UInt64 = 0
            while process.isRunning && nowNs() < updatesDeadline {
                _ = try checkForeground(childPid)
                if nowNs() - lastItemPoll >= 50_000_000 {
                    lastItemPoll = nowNs()
                    visible = itemsVisible(applicationAX, count: options.count)
                    if visible { break }
                }
                pumpEvents()
            }
            if visible {
                if populateIPC { ipcAppliedMs = elapsedMs(start) }
                _ = try checkForeground(childPid)
                if options.accept && focusedQuery(focusedAX, childPid: childPid) != nil {
                    returnMs = elapsedMs(start)
                    try postReturn()
                    let returnDeadline = deadline(nowNs(), 2000)
                    while process.isRunning && nowNs() < returnDeadline {
                        _ = try checkForeground(childPid)
                        pumpEvents()
                    }
                    if !process.isRunning {
                        process.waitUntilExit()
                        let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
                        acceptSuccess = process.terminationStatus == 0 && validSelectionOutput(output, ipc: options.mode == "ipc")
                    }
                }
            }
        }
        stopChild(process)
        if !options.accept && process.terminationStatus != 2 {
            throw BenchError("Escape cancellation regression: expected exit status 2")
        }
        if let recorder {
            recorder.waitUntilExit()
            guard recorder.terminationStatus == 0, let recordingPath,
                  FileManager.default.fileExists(atPath: recordingPath) else {
                throw BenchError("screen recording failed")
            }
        }
        var result: [String: Any] = [
            "type": "trial", "trial": number, "mode": options.mode, "count": options.count,
            "show_icons": options.showIcons,
            "prefill": options.prefill, "recording": recordingPath as Any? ?? NSNull(),
            "ready": options.ready, "delay_ms": options.ready ? NSNull() : delayMs as Any,
            "stdin_delay_ms": options.stdinDelayMs, "spawn_return_ms": spawnReturnMs,
            "foreground_ms": activation.foregroundMs as Any? ?? NSNull(),
            "focused_ms": focusedMs as Any? ?? NSNull(),
            "input_acceptance_ms": acceptedMs as Any? ?? NSNull(),
            "sent_ms": sentMs, "key_lateness_ms": latenessMs,
            "timing_late": latenessMs.contains(where: { $0 > 5 }),
            "first_key_late": (latenessMs.first ?? 0) > 5, "query": query as Any? ?? NSNull(), "sink_prefix": sinkPrefix,
            "complete": complete, "lost_chars": max(0, characters.count - received),
            "sent_chars": nextKey, "exit_status": process.terminationStatus,
            "accept_requested": options.accept, "accept_success": options.accept ? acceptSuccess as Any : NSNull(),
            "return_ms": returnMs as Any? ?? NSNull(), "ipc_items": populateIPC,
            "ipc_sent_ms": ipcSentMs as Any? ?? NSNull(), "ipc_applied_ms": ipcAppliedMs as Any? ?? NSNull(),
            "ipc_items_applied": populateIPC ? (ipcAppliedMs != nil) as Any : NSNull(),
            "ctl_exit_status": controller != nil && !controller!.isRunning ? controller!.terminationStatus as Any : NSNull(),
        ]
        if options.profile {
            let output = profilePipe.fileHandleForReading.readDataToEndOfFile()
            var stages: [String: Double] = [:]
            var processEntryMs: Double?
            for line in String(decoding: output, as: UTF8.self).split(separator: "\n") {
                let parts = line.split(separator: " ")
                if parts.count == 2, parts[0] == "startup-profile",
                   parts[1].hasPrefix("process_start_ns="),
                   let childStart = UInt64(parts[1].dropFirst("process_start_ns=".count)), childStart >= start {
                    processEntryMs = Double(childStart - start) / 1_000_000
                    continue
                }
                guard parts.count == 3, parts[0] == "startup-profile",
                      parts[1].hasPrefix("stage="), parts[2].hasPrefix("elapsed_ms="),
                      let time = Double(parts[2].dropFirst("elapsed_ms=".count)) else { continue }
                stages[String(parts[1].dropFirst("stage=".count))] = time
            }
            result["phases_ms"] = stages
            if let processEntryMs {
                result["process_entry_ms"] = processEntryMs
                result["phases_from_trigger_ms"] = stages.mapValues { $0 + processEntryMs }
            }
        }
        guard focusedMs != nil else {
            try jsonLine(result)
            throw BenchError("child never exposed a focused AX text editor")
        }
        return result
    }

    func run() throws {
        defer { restore() }
        var number = 0
        let delays = options.ready ? [0.0] : options.delays
        for delay in delays {
            var results: [[String: Any]] = []
            for _ in 0..<options.runs {
                number += 1
                let result = try trial(number, delayMs: delay)
                try jsonLine(result)
                results.append(result)
            }
            let focus = results.compactMap { $0["focused_ms"] as? Double }.sorted()
            let acceptance = results.compactMap { $0["input_acceptance_ms"] as? Double }.sorted()
            let failed = results.filter { ($0["complete"] as? Bool) != true }.count
            let lost = results.compactMap { $0["lost_chars"] as? Int }.reduce(0, +)
            let acceptFailures = results.filter { ($0["accept_requested"] as? Bool) == true && ($0["accept_success"] as? Bool) != true }.count
            let ipcFailures = results.filter { ($0["ipc_items"] as? Bool) == true && ($0["ipc_items_applied"] as? Bool) != true }.count
            let firstLate = results.filter { ($0["first_key_late"] as? Bool) == true }.count
            let late = results.filter { ($0["timing_late"] as? Bool) == true }.count
            func percentile(_ values: [Double], _ fraction: Double) -> Any {
                guard !values.isEmpty else { return NSNull() }
                return values[max(0, Int(ceil(Double(values.count) * fraction)) - 1)]
            }
            try jsonLine([
                "type": "summary", "mode": options.mode, "ready": options.ready,
                "delay_ms": options.ready ? NSNull() : delay as Any,
                "runs": results.count, "incomplete_trials": failed, "lost_chars": lost,
                "late_trials": late, "any_key_late_trials": late, "first_key_late_trials": firstLate,
                "accept_failures": acceptFailures, "ipc_update_failures": ipcFailures,
                "focus_median_ms": percentile(focus, 0.5), "focus_p95_ms": percentile(focus, 0.95),
                "input_median_ms": percentile(acceptance, 0.5), "input_p95_ms": percentile(acceptance, 0.95),
            ])
            let timing = focus.isEmpty ? "n/a" : String(format: "%.1f/%.1f", focus[(focus.count - 1) / 2], focus[max(0, Int(ceil(Double(focus.count) * 0.95)) - 1)])
            let label = options.ready ? "ready" : "delay=\(delay)ms"
            stderr("\(options.mode) \(label): focus median/p95=\(timing)ms, incomplete=\(failed)/\(results.count), lost=\(lost) chars")
            if options.ready && failed > 0 { throw BenchError("focused keyboard regression: incomplete query") }
            if ipcFailures > 0 { throw BenchError("IPC update regression: synthetic list never became visible") }
            if acceptFailures > 0 { throw BenchError("Return selection regression: unexpected or missing synthetic output") }
        }
    }
}

do {
    let options = try parseOptions()
    guard AXIsProcessTrusted() else { throw BenchError("Accessibility permission missing for benchmark executable; no prompt requested") }
    guard CGPreflightPostEventAccess() else { throw BenchError("event-posting permission missing; no prompt requested") }
    if !options.recordDir.isEmpty && !CGPreflightScreenCaptureAccess() {
        throw BenchError("Screen Recording permission missing; no prompt requested")
    }
    signal(SIGPIPE, SIG_IGN)
    let harness = Harness(options)
    try harness.run()
} catch {
    stderr("startup-bench: \(error)")
    exit(1)
}
