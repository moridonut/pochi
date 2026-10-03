// pochi — a keyboard-driven "open with" picker for macOS
// Inspired by ぽちエス (PochiS) / esExt for Windows.
//
// Usage:  pochi [-c config] <file> [file...]
//
// MIT License

import Cocoa
import Foundation

// MARK: - Model

struct Item {
    var key: String      // 1-character accelerator ("" = none)
    var label: String
    var command: String
}

indirect enum Node {
    case item(Item)
    case separator
    case submenu(String, [Node])
}

// MARK: - Config parsing

/// Config format (see config.example.conf):
///
///   # comment
///   [.txt .md]              section: one or more extensions
///   [folder]                section: directories
///   [*]                     section: fallback when extension not listed
///   [all]                   appended to every menu
///
///   v | Vim | vim %P        key | label | command
///   -                       separator
///   { Editors               submenu start
///   }                       submenu end
func parseConfig(_ text: String) -> [String: [Node]] {
    var result: [String: [Node]] = [:]
    var sections: [String] = []
    var stack: [[Node]] = [[]]
    var names: [String] = []

    func closeOpenSubmenus() {
        while !names.isEmpty {
            let nodes = stack.removeLast()
            let name = names.removeLast()
            stack[stack.count - 1].append(.submenu(name, nodes))
        }
    }

    func flush() {
        closeOpenSubmenus()
        let nodes = stack[0]
        if !sections.isEmpty && !nodes.isEmpty {
            for s in sections {
                result[s, default: []].append(contentsOf: nodes)
            }
        }
        stack = [[]]
    }

    for rawLine in text.components(separatedBy: .newlines) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty { continue }
        if line.hasPrefix("#") || line.hasPrefix(";") { continue }

        // Section header
        if line.hasPrefix("[") && line.hasSuffix("]") {
            flush()
            let inner = String(line.dropFirst().dropLast())
            sections = inner
                .components(separatedBy: .whitespaces)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
            continue
        }

        // Submenu start / end
        if line.hasPrefix("{") {
            let name = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
            names.append(name.isEmpty ? "..." : name)
            stack.append([])
            continue
        }
        if line.hasPrefix("}") {
            if !names.isEmpty {
                let nodes = stack.removeLast()
                let name = names.removeLast()
                stack[stack.count - 1].append(.submenu(name, nodes))
            }
            continue
        }

        // Separator
        if line == "-" || line == "--" || line.hasPrefix("---") {
            stack[stack.count - 1].append(.separator)
            continue
        }

        // Item:  key | label | command
        let parts = line.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        if parts.count >= 3 {
            let key = String(parts[0].prefix(1)).lowercased()
            let label = parts[1]
            let command = parts[2...].joined(separator: "|")
            stack[stack.count - 1].append(.item(Item(key: key, label: label, command: command)))
        } else if parts.count == 2 {
            // label | command  (no accelerator)
            stack[stack.count - 1].append(.item(Item(key: "", label: parts[0], command: parts[1])))
        }
    }
    flush()
    return result
}

// MARK: - Macro expansion

func shellQuote(_ s: String) -> String {
    return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// Ask the user for a value (the %X macro).
func promptForInput(title: String, initial: String) -> String? {
    let alert = NSAlert()
    alert.messageText = title
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Cancel")
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    field.stringValue = initial
    alert.accessoryView = field
    alert.window.initialFirstResponder = field
    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    if response == .alertFirstButtonReturn {
        return field.stringValue
    }
    return nil
}

/// Expand %P %D %N %F %E %A %B %M %X and %% in `command`.
/// Every substituted value is shell-quoted, so configs write `%P`, not `"%P"`.
func expand(_ command: String, files: [String], label: String) -> String? {
    guard let first = files.first else { return nil }
    let url = URL(fileURLWithPath: first)
    let dir = url.deletingLastPathComponent()

    var map: [Character: String] = [:]
    map["P"] = first                                   // full path
    map["D"] = dir.path                                // containing folder
    map["N"] = url.lastPathComponent                   // name with extension
    map["F"] = dir.lastPathComponent                   // containing folder name
    map["E"] = url.pathExtension                       // extension
    map["A"] = url.deletingPathExtension().lastPathComponent
    map["B"] = url.deletingPathExtension().path
    map["M"] = files.map { shellQuote($0) }.joined(separator: " ")

    var out = ""
    var i = command.startIndex
    while i < command.endIndex {
        let ch = command[i]
        if ch != "%" {
            out.append(ch)
            i = command.index(after: i)
            continue
        }
        let next = command.index(after: i)
        if next >= command.endIndex {
            out.append(ch)
            break
        }
        let code = command[next]

        if code == "%" {
            out.append("%")
            i = command.index(after: next)
            continue
        }

        if code == "X" {
            // %X  or  %X"initial value"
            var initial = ""
            var after = command.index(after: next)
            if after < command.endIndex, command[after] == "\"" {
                let valueStart = command.index(after: after)
                if let close = command[valueStart...].firstIndex(of: "\"") {
                    initial = String(command[valueStart..<close])
                    after = command.index(after: close)
                }
            }
            // macros are allowed inside the initial value
            for (k, v) in map { initial = initial.replacingOccurrences(of: "%\(k)", with: v) }
            guard let typed = promptForInput(title: label, initial: initial) else {
                return nil   // cancelled
            }
            out.append(shellQuote(typed))
            i = after
            continue
        }

        if let value = map[code] {
            // %M is pre-quoted (it is a list); the rest get quoted here.
            out.append(code == "M" ? value : shellQuote(value))
            i = command.index(after: next)
            continue
        }

        out.append(ch)
        i = next
    }
    return out
}

// MARK: - Menu

final class Handler: NSObject {
    var chosen: Item?
    @objc func pick(_ sender: NSMenuItem) {
        chosen = sender.representedObject as? Item
    }
}

func buildMenu(_ nodes: [Node], handler: Handler) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    for node in nodes {
        switch node {
        case .separator:
            menu.addItem(.separator())
        case .item(let item):
            let mi = NSMenuItem(title: item.label,
                                action: #selector(Handler.pick(_:)),
                                keyEquivalent: item.key)
            mi.keyEquivalentModifierMask = []
            mi.target = handler
            mi.representedObject = item
            mi.isEnabled = true
            menu.addItem(mi)
        case .submenu(let name, let children):
            let mi = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            mi.isEnabled = true
            mi.submenu = buildMenu(children, handler: handler)
            menu.addItem(mi)
        }
    }
    return menu
}

// MARK: - Helpers

func die(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    appendLog(message)
    exit(1)
}

// MARK: - Log
//
// Every command pochi runs, its stderr and its exit status are appended to
// ~/Library/Logs/pochi.log (override with POCHI_LOG). Console.app shows it
// under "Log Reports"; `tail -f ~/Library/Logs/pochi.log` works too.

let logURL: URL = {
    if let p = ProcessInfo.processInfo.environment["POCHI_LOG"], !p.isEmpty {
        return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/pochi.log")
}()

/// Opens the log for appending, rotating it to pochi.log.old past 1 MB.
func openLog() -> FileHandle? {
    let fm = FileManager.default
    try? fm.createDirectory(at: logURL.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
    if let size = (try? fm.attributesOfItem(atPath: logURL.path))?[.size] as? Int,
       size > 1_000_000 {
        let old = logURL.appendingPathExtension("old")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: logURL, to: old)
    }
    // O_APPEND so that the child (which may outlive us) and later log lines
    // never overwrite each other.
    let fd = open(logURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard fd >= 0 else { return nil }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
}

func logSize() -> UInt64 {
    ((try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? UInt64) ?? 0
}

func appendLog(_ message: String) {
    guard let h = openLog() else { return }
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                            formatOptions: [.withInternetDateTime])
    h.write("[\(stamp)] \(message)\n".data(using: .utf8)!)
    h.closeFile()
}

/// Directories prepended to PATH for child commands. Double Commander (and
/// anything launched from Finder/Dock) gives us only /usr/bin:/bin:..., so
/// helpers like open-in-iterm would not be found without this.
func extraPathDirs() -> [String] {
    var dirs: [String] = []
    // Helpers bundled by build.sh: Pochi.app/Contents/Resources/bin
    if let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() {
        dirs.append(exe.deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/bin").path)
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    dirs += [home + "/bin", home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
    return dirs
}

func runCommand(_ command: String, cwd: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", command]
    p.currentDirectoryURL = URL(fileURLWithPath: cwd)
    // Double Commander launches us without LANG; make sure children get UTF-8.
    var env = ProcessInfo.processInfo.environment
    if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
    if env["LC_CTYPE"] == nil { env["LC_CTYPE"] = "UTF-8" }
    let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    env["PATH"] = (extraPathDirs() + [path]).joined(separator: ":")
    p.environment = env

    // The child's stderr goes straight into the log (a file, not a pipe, so a
    // long-running child never blocks or gets SIGPIPE after we exit). If the
    // command fails quickly we also show it — when launched from Double
    // Commander there is no terminal to see "command not found" in.
    appendLog("run: \(command)\n    cwd: \(cwd)\n    PATH: \(env["PATH"]!)")
    let log = openLog()
    let start = logSize()
    if let h = log { p.standardError = h }

    do {
        try p.run()
    } catch {
        die("pochi: failed to run: \(command)")
    }
    log?.closeFile()   // the child keeps its own copy

    let deadline = Date().addingTimeInterval(2.0)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning {
        appendLog("still running after 2s (pid \(p.processIdentifier)); later stderr is appended below")
        return
    }

    // This run's stderr = everything the child wrote after `start`.
    var err = ""
    if let r = try? FileHandle(forReadingFrom: logURL) {
        r.seek(toFileOffset: start)
        err = String(decoding: r.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        r.closeFile()
    }
    appendLog("exit \(p.terminationStatus)")
    if p.terminationStatus == 0 { return }

    FileHandle.standardError.write((err + "\n").data(using: .utf8)!)
    let alert = NSAlert()
    alert.messageText = "pochi: コマンドが失敗しました（終了コード \(p.terminationStatus)）"
    alert.informativeText = command + (err.isEmpty ? "" : "\n\n" + err)
        + "\n\nログ: " + logURL.path
    NSApplication.shared.activate(ignoringOtherApps: true)
    alert.runModal()
}

func defaultConfigPath() -> String {
    if let p = ProcessInfo.processInfo.environment["POCHI_CONFIG"], !p.isEmpty { return p }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return home + "/.config/pochi/config.conf"
}

// MARK: - Main

var args = Array(CommandLine.arguments.dropFirst())
var configPath = defaultConfigPath()

var files: [String] = []
var idx = 0
while idx < args.count {
    let a = args[idx]
    if a == "-c" || a == "--config" {
        idx += 1
        if idx < args.count { configPath = args[idx] }
    } else if a == "-h" || a == "--help" {
        print("""
        pochi — keyboard-driven "open with" picker for macOS

          pochi [-c config] <file> [file...]

        Config: \(defaultConfigPath())
                (override with -c or the POCHI_CONFIG environment variable)
        """)
        exit(0)
    } else {
        files.append(a)
    }
    idx += 1
}

if files.isEmpty { die("pochi: no file given. Try --help.") }

// Resolve to absolute paths
files = files.map { $0.hasPrefix("/") ? $0 : FileManager.default.currentDirectoryPath + "/" + $0 }

guard let text = try? String(contentsOfFile: configPath, encoding: .utf8) else {
    // No config yet: fall back to the system default application.
    runCommand("open \(files.map { shellQuote($0) }.joined(separator: " "))",
               cwd: FileManager.default.currentDirectoryPath)
    exit(0)
}

let config = parseConfig(text)

// Pick the section for this file
var isDir: ObjCBool = false
FileManager.default.fileExists(atPath: files[0], isDirectory: &isDir)
let ext = "." + URL(fileURLWithPath: files[0]).pathExtension.lowercased()
let sectionKey = isDir.boolValue ? "folder" : ext

var nodes: [Node] = config[sectionKey] ?? config["*"] ?? []
nodes.append(contentsOf: config["all"] ?? [])

// Nothing configured → system default
func hasItem(_ ns: [Node]) -> Bool {
    for n in ns {
        switch n {
        case .item: return true
        case .submenu(_, let c): if hasItem(c) { return true }
        case .separator: continue
        }
    }
    return false
}

if !hasItem(nodes) {
    runCommand("open \(files.map { shellQuote($0) }.joined(separator: " "))",
               cwd: FileManager.default.currentDirectoryPath)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let handler = Handler()

// Exactly one entry and no submenu → run it straight away (like ぽちエス)
var flat: [Item] = []
func collect(_ ns: [Node]) {
    for n in ns {
        if case .item(let it) = n { flat.append(it) }
        if case .submenu(_, let c) = n { collect(c) }
    }
}
collect(nodes)

var selected: Item?
if flat.count == 1 {
    selected = flat[0]
} else {
    let menu = buildMenu(nodes, handler: handler)
    app.activate(ignoringOtherApps: true)
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    selected = handler.chosen
}

guard let item = selected else { exit(0) }   // cancelled

guard let command = expand(item.command, files: files, label: item.label) else {
    exit(0)   // %X cancelled
}

runCommand(command, cwd: URL(fileURLWithPath: files[0]).deletingLastPathComponent().path)
exit(0)
