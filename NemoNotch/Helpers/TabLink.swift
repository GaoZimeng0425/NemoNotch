import Foundation

/// Tab-level jump links (evlat's approach): terminals that can select their
/// own tab publish a link in the environment they give their child processes,
/// so opening the URL with `NSWorkspace` makes the terminal reveal that tab —
/// no Accessibility, no Apple Events, no per-app scripting. Apps that publish
/// nothing (Terminal.app, Ghostty) simply resolve no link and the jump falls
/// back to pid/bundle activation.
///
/// Matched by VARIABLE NAME, not bundle id: the variables are namespaced by
/// the terminal that sets them, and the value guards (scheme prefixes, id
/// shapes) keep a stale or foreign value from opening something random.
enum TabLink {
    /// Pure: pick the first resolvable link from a CLI's inherited
    /// environment. Unit-tested.
    static func resolve(_ environment: [String: String]) -> URL? {
        if let id = environment["ITERM_SESSION_ID"], let url = iterm2(id) {
            return url
        }
        for (variable, prefix) in [
            ("WARP_FOCUS_URL", "warp://session/"),
            ("BATERI_TAB_URL", "bateri://tab/"),
            ("LC_BATERI_TAB_URL", "bateri://tab/"),
            ("METALTERM_TAB_URL", "metalterm://tab/"),
        ] {
            if let value = environment[variable], value.hasPrefix(prefix), value.count > prefix.count {
                return URL(string: value)
            }
        }
        if let id = environment["CLAUDE_CODE_HOST_SESSION_ID"], let url = claudeDesktop(id) {
            return url
        }
        if let workspace = environment["CMUX_WORKSPACE_ID"].flatMap(UUID.init(uuidString:)),
           let surface = environment["CMUX_SURFACE_ID"].flatMap(UUID.init(uuidString:)) {
            return URL(string: "cmux://workspace/\(workspace.uuidString)/surface/\(surface.uuidString)")
        }
        return nil
    }

    /// `ITERM_SESSION_ID` is `<terminal id>:<session uuid>` (e.g.
    /// `w0t0p0:5E9F…`); the full value goes into the reveal URL untouched.
    private static func iterm2(_ value: String) -> URL? {
        guard let colon = value.firstIndex(of: ":") else { return nil }
        let terminal = value[..<colon]
        let session = value[value.index(after: colon)...]
        guard isID(terminal, allowHyphen: false), isID(session, allowHyphen: true) else { return nil }
        return URL(string: "iterm2:reveal?sessionid=\(value)")
    }

    /// The Claude desktop app's host session id is `local_<uuid-ish>`.
    private static func claudeDesktop(_ value: String) -> URL? {
        guard value.hasPrefix("local_"), isID(value.dropFirst("local_".count), allowHyphen: true) else {
            return nil
        }
        return URL(string: "claude://code/continue?session=\(value)")
    }

    private static func isID(_ value: some StringProtocol, allowHyphen: Bool) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isLetter || $0.isNumber || (allowHyphen && $0 == "-") }
    }
}

/// Reading another process's inherited environment: `KERN_PROCARGS2` is a
/// public sysctl, readable without a permission for the user's own processes.
/// Apple-signed binaries (`/bin/zsh`, `/usr/bin/ssh`) expose their name and
/// no strings to other processes — agent CLIs (node, bun, python) are not
/// signed and read fine, and the CLI is the process that inherited the
/// terminal's tab link.
enum ProcessEnvironment {
    /// `exec`-time environment of `pid` as a dictionary (first occurrence of a
    /// name wins, mirroring getenv). Empty when the area is not readable.
    static func of(_ pid: Int32) -> [String: String] {
        guard let strings = strings(pid) else { return [:] }
        var out: [String: String] = [:]
        for string in strings {
            guard let equals = string.firstIndex(of: "=") else { continue }
            let name = String(string[..<equals])
            guard !name.isEmpty else { continue }
            if out[name] == nil {
                out[name] = String(string[string.index(after: equals)...])
            }
        }
        return out
    }

    /// Raw `exec`-time environment strings (`NAME=value`). Same as `of`, for
    /// callers that want the order or non-`=` entries.
    static func strings(_ pid: Int32) -> [String]? {
        guard let buffer = procArgs(pid) else { return nil }
        return split(procArgs: buffer).environment
    }

    /// The `KERN_PROCARGS2` area: an `Int32` argc, then the exec path, the
    /// arguments, null padding, then the environment strings.
    static func procArgs(_ pid: Int32) -> [UInt8]? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        return Array(buffer[..<size])
    }

    /// Pure split of a `KERN_PROCARGS2` buffer into arguments and environment.
    /// A short or truncated buffer yields what it holds, never reads past it.
    static func split(procArgs buffer: [UInt8]) -> (arguments: [String], environment: [String]) {
        let head = MemoryLayout<Int32>.size
        guard buffer.count > head else { return ([], []) }
        let argc = buffer[0 ..< head].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        // Skip the exec path (first NUL-terminated string after argc), then
        // the padding NULs that align the string area.
        var index = buffer[head...].firstIndex(of: 0) ?? buffer.endIndex
        while index < buffer.endIndex, buffer[index] == 0 {
            index += 1
        }
        var arguments: [String] = []
        var environment: [String] = []
        while index < buffer.endIndex {
            let end = buffer[index...].firstIndex(of: 0) ?? buffer.endIndex
            let string = String(decoding: buffer[index ..< end], as: UTF8.self)
            // An empty argument is a real one (`claude --flag ""`); an empty
            // string after the arguments ends the environment.
            if arguments.count < argc {
                arguments.append(string)
            } else if end == index {
                break
            } else {
                environment.append(string)
            }
            index = end < buffer.endIndex ? buffer.index(after: end) : buffer.endIndex
        }
        return (arguments, environment)
    }
}
