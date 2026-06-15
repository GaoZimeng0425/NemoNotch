import Foundation

/// Locates the installed gemini-cli and extracts its OAuth client_id/secret
/// from the bundled JS. Ported from CodexBar's GeminiStatusProbe. These are
/// public "installed application" credentials embedded in gemini-cli's source;
/// reading them at runtime means a Google key rotation can't break us.
enum GeminiOAuthClientLocator {
    struct ClientCredentials: Equatable, Sendable {
        let clientId: String
        let clientSecret: String
    }

    // MARK: - Pure parsing (unit-tested)

    /// Regex-extracts `OAUTH_CLIENT_ID` / `OAUTH_CLIENT_SECRET` from JS source.
    static func parse(from content: String) -> ClientCredentials? {
        guard let id = firstMatch(#"OAUTH_CLIENT_ID\s*=\s*['"]([\w\-\.]+)['"]"#, in: content),
              let secret = firstMatch(#"OAUTH_CLIENT_SECRET\s*=\s*['"]([\w\-]+)['"]"#, in: content)
        else { return nil }
        return ClientCredentials(clientId: id, clientSecret: secret)
    }

    private static func firstMatch(_ pattern: String, in content: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(content.startIndex..., in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let captured = Range(match.range(at: 1), in: content) else { return nil }
        return String(content[captured])
    }

    // MARK: - Resolution (integration)

    /// Full resolution: locate the gemini binary, then read its OAuth constants.
    static func resolve() -> ClientCredentials? {
        guard let binary = locateGeminiBinary() else {
            LogService.warn("Gemini OAuth: gemini binary not found", category: "UsageQuotaService")
            return nil
        }
        let real = URL(fileURLWithPath: binary).resolvingSymlinksInPath().path
        if let creds = fromLegacyPaths(realGeminiPath: real) { return creds }
        if let root = findPackageRoot(startingAt: real), let creds = fromPackageRoot(root) { return creds }
        LogService.warn("Gemini OAuth: could not extract client credentials", category: "UsageQuotaService")
        return nil
    }

    private static func locateGeminiBinary() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.bun/bin/gemini",
            "/opt/homebrew/bin/gemini",
            "/usr/local/bin/gemini",
            "\(home)/.npm-global/bin/gemini",
            "\(home)/.local/bin/gemini",
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return path
        }
        // GUI apps don't inherit the user's shell PATH, so fall back to a login shell.
        return loginShellWhich("gemini")
    }

    /// Runs `which <tool>` through a login shell so a GUI app (which inherits a
    /// minimal PATH) still resolves tools installed under the user's shell PATH.
    /// The tool is passed as a positional arg (`$1`) rather than interpolated, and
    /// the wait is bounded so a slow login shell can't stall the quota refresh.
    private static func loginShellWhich(_ tool: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", #"which "$1""#, "zsh", tool]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit()
            done.signal()
        }
        if done.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    private static let oauthFile = "dist/src/code_assist/oauth2.js"

    private static func fromLegacyPaths(realGeminiPath: String) -> ClientCredentials? {
        let binDir = (realGeminiPath as NSString).deletingLastPathComponent
        let baseDir = (binDir as NSString).deletingLastPathComponent
        let nested = "node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/\(oauthFile)"
        let nixShare = "share/gemini-cli/node_modules/@google/gemini-cli-core/\(oauthFile)"
        let paths = [
            "\(baseDir)/libexec/lib/\(nested)",
            "\(baseDir)/lib/\(nested)",
            "\(baseDir)/\(nixShare)",
            "\(baseDir)/../gemini-cli-core/\(oauthFile)",
            "\(baseDir)/node_modules/@google/gemini-cli-core/\(oauthFile)",
        ]
        for path in paths {
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               let creds = parse(from: content) { return creds }
        }
        return nil
    }

    /// Ascend ≤8 dirs looking for `@google/gemini-cli`'s package.json, then read
    /// `oauth2.js`; falls back to scanning the bundle (this machine's bun layout).
    private static func findPackageRoot(startingAt path: String) -> String? {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: current.path, isDirectory: &isDir) || !isDir.boolValue {
            current.deleteLastPathComponent()
        }
        for _ in 0 ... 8 {
            let pkg = current.appendingPathComponent("package.json")
            if let data = try? Data(contentsOf: pkg),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               json["name"] as? String == "@google/gemini-cli" {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }

    private static func fromPackageRoot(_ root: String) -> ClientCredentials? {
        let candidates = [
            "\(root)/\(oauthFile)",
            "\(root)/node_modules/@google/gemini-cli-core/\(oauthFile)",
        ]
        for path in candidates {
            if let content = try? String(contentsOfFile: path, encoding: .utf8),
               let creds = parse(from: content) { return creds }
        }
        return fromBundle(packageRoot: root)
    }

    /// BFS the `bundle/` dir from gemini.js following relative `./*.js` imports,
    /// then any sibling `.js`. Matches gemini-cli's single-file bundle layout.
    private static func fromBundle(packageRoot: String) -> ClientCredentials? {
        let bundleRoot = URL(fileURLWithPath: packageRoot).appendingPathComponent("bundle", isDirectory: true)
        let entry = bundleRoot.appendingPathComponent("gemini.js")
        guard FileManager.default.fileExists(atPath: entry.path) else { return nil }

        var pending = [entry]
        var visited = Set<String>()
        while !pending.isEmpty {
            let url = pending.removeFirst()
            let key = url.standardizedFileURL.path
            guard visited.insert(key).inserted,
                  let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let creds = parse(from: content) { return creds }
            for imp in relativeImports(in: content) {
                let next = URL(fileURLWithPath: imp, relativeTo: url.deletingLastPathComponent()).standardizedFileURL
                if next.path.hasPrefix(bundleRoot.path) { pending.append(next) }
            }
        }

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: bundleRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        for url in files where url.pathExtension == "js" && !visited.contains(url.standardizedFileURL.path) {
            if let content = try? String(contentsOf: url, encoding: .utf8),
               let creds = parse(from: content) { return creds }
        }
        return nil
    }

    private static func relativeImports(in content: String) -> [String] {
        let patterns = [
            #"(?:import|export)\s+(?:[^;]*?\s+from\s+)?["'](\./[^"']+\.js)["']"#,
            #"import\(\s*["'](\./[^"']+\.js)["']\s*\)"#,
        ]
        var out: [String] = []
        var seen = Set<String>()
        let range = NSRange(content.startIndex..., in: content)
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: content, range: range) {
                guard let r = Range(match.range(at: 1), in: content) else { continue }
                let path = String(content[r])
                if seen.insert(path).inserted { out.append(path) }
            }
        }
        return out
    }
}
