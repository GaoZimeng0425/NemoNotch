import Foundation
import Synchronization

/// Resolves a model id → its context-window size (in tokens), used only for
/// display (the "x / 1M" label and the context-usage bar).
///
/// Resolution order (first hit wins):
/// 1. `limits` — a curated, hardcoded table. The source of truth; never
///    overridden. Keeps the app correct offline / on a cold first launch
///    before any network fetch lands.
/// 2. `overlay` — a lazily-fetched map from OpenRouter's public model
///    catalog (`GET https://openrouter.ai/api/v1/models`, no auth), cached
///    to disk. Fills in models the curated table doesn't list yet (e.g. a
///    brand-new GLM/Gemini release), so new models show a real value without
///    a code change.
/// 3. Claude table (`claudeLimits`, before the overlay) — Claude ids are
///    dated (`claude-opus-4-8-20250805`) or dot-versioned (`claude-opus-4.8`),
///    so they match by family-version prefix. Claude Code runs a model with
///    200K or 1M and its transcript never says which, so an unlisted Claude
///    id is 200K, and `limit(for:observed:)` upgrades any Claude id to 1M
///    once a call was seen holding more than its listed window (agent-hud's
///    rule). OpenRouter's Claude windows are the API's, not Claude Code's —
///    that is why this step runs before the overlay.
/// 4. `defaultValue`.
enum ModelContextWindow {
    static let limits: [String: Int] = [
        "gemini-3-flash": 1_048_576,
        "gemini-3-flash-preview": 1_048_576,
        "gemini-3-pro": 2_097_152,
        "gemini-3-pro-preview": 2_097_152,
        "gemini-3.5-flash": 2_097_152,
        "gemini-3.5-pro": 4_194_304,
        "mimo-v2-pro": 1_000_000,
        "glm-5.1": 200_000,
        "glm-5.2": 1_048_576,
        "glm-5.3": 1_310_720,
        "glm-5.3-flash": 1_310_720,
    ]
    static let defaultValue = 1_048_576

    /// OpenRouter-fetched overlay, keyed by normalized bare model id. Empty
    /// until `warm()`/`refresh()` populates it. `Mutex` keeps the sync
    /// `limit(for:)` read thread-safe without isolating the call site.
    private static let overlay = Mutex<[String: Int]>([:])

    static func limit(for model: String) -> Int {
        // 1. Curated exact match (never overridden by the catalog).
        if let exact = limits[model] {
            return exact
        }
        // 2. Claude (dated/dot-versioned ids; Claude Code's windows, not the API's).
        if let claude = claudeLimit(for: model) {
            return claude
        }
        // 3. OpenRouter catalog overlay (auto-discovered, fills gaps).
        let key = normalize(model)
        if let fetched = overlay.withLock({ $0[key] }) {
            return fetched
        }
        // 4. Default.
        return defaultValue
    }

    /// The window a session's calls actually ran in: `limit(for:)`, except a
    /// Claude session seen holding more than that ran with 1M.
    static func limit(for model: String, observed: Int) -> Int {
        let listed = limit(for: model)
        guard observed > listed, claudeLimit(for: model) != nil else { return listed }
        return max(listed, claudeOneMillion)
    }

    static let claudeOneMillion = 1_000_000
    static let claudeDefault = 200_000

    /// Claude Code's window per family-version (agent-hud-open's catalog),
    /// matched as a prefix of the bare id with dots read as dashes. Longest
    /// prefix wins (`claude-opus-4-5` before `claude-opus-4`).
    static let claudeLimits: [String: Int] = [
        "claude-fable-5": 1_000_000,
        "claude-mythos-5": 1_000_000,
        "claude-opus-5": 1_000_000,
        "claude-opus-4-8": 1_000_000,
        "claude-opus-4-7": 1_000_000,
        "claude-opus-4-6": 1_000_000,
        "claude-opus-4-5": 200_000,
        "claude-opus-4-1": 200_000,
        "claude-opus-4": 200_000,
        "claude-sonnet-5": 1_000_000,
        "claude-sonnet-4-6": 1_000_000,
        "claude-sonnet-4-5": 200_000,
        "claude-sonnet-4": 200_000,
        "claude-haiku-4-5": 200_000,
        "claude-3-5-haiku": 200_000,
    ]

    /// nil for a non-Claude id. A `[1m]` suffix (Claude Code's own model
    /// alias) says 1M outright.
    static func claudeLimit(for model: String) -> Int? {
        let key = normalize(model).replacingOccurrences(of: ".", with: "-")
        guard key.hasPrefix("claude-") else { return nil }
        if key.hasSuffix("[1m]") {
            return claudeOneMillion
        }
        let match = claudeLimits.keys
            .filter { key == $0 || key.hasPrefix($0 + "-") }
            .max(by: { $0.count < $1.count })
        return match.flatMap { claudeLimits[$0] } ?? claudeDefault
    }

    /// Normalize an id to a single lookup key: lowercase, and strip any
    /// OpenRouter vendor prefix (`z-ai/glm-5.2` → `glm-5.2`). Bare CLI ids
    /// (`glm-5.2`) pass through unchanged.
    static func normalize(_ id: String) -> String {
        let trimmed = id.lowercased()
        if let slash = trimmed.lastIndex(of: "/") {
            return String(trimmed[trimmed.index(after: slash)...])
        }
        return trimmed
    }

    // MARK: - OpenRouter catalog refresh

    private static let catalogURL = URL(string: "https://openrouter.ai/api/v1/models")!
    /// `~/.NemoNotch/model-context-cache.json` — `{ "fetchedAt": <epoch>, "limits": {…} }`.
    private static let cacheURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".NemoNotch/model-context-cache.json")
    /// Re-fetch the catalog at most this often. The catalog changes rarely,
    /// so a few days keeps outbound calls negligible.
    private static let cacheTTL: TimeInterval = 86400 * 3

    /// Load the cached overlay if fresh; otherwise kick a background refresh.
    /// Offline-safe and idempotent — call once at launch.
    static func warm() {
        if loadCache() {
            LogService.info(
                "Model catalog: loaded \(overlay.withLock { $0.count }) cached entries",
                category: "ModelContextWindow"
            )
        } else {
            Task { await refresh() }
        }
    }

    /// Fetch the OpenRouter catalog, parse `context_length`, and cache the
    /// result. Failures are logged and swallowed — the curated table still
    /// resolves every lookup.
    static func refresh() async {
        var request = URLRequest(url: catalogURL, timeoutInterval: 20)
        request.setValue("NemoNotch", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(status) else {
                LogService.warn("Model catalog: HTTP \(status)", category: "ModelContextWindow")
                return
            }
            let parsed = parse(data: data)
            guard !parsed.isEmpty else {
                LogService.warn("Model catalog: parsed 0 entries", category: "ModelContextWindow")
                return
            }
            overlay.withLock { $0 = parsed }
            writeCache(limits: parsed)
            LogService.info(
                "Model catalog: fetched \(parsed.count) entries from OpenRouter",
                category: "ModelContextWindow"
            )
        } catch {
            LogService.warn(
                "Model catalog fetch failed: \(error.localizedDescription)",
                category: "ModelContextWindow"
            )
        }
    }

    /// Extract `{ normalizedId: context_length }` from an OpenRouter models
    /// payload. Pure function — tested without network.
    static func parse(data: Data) -> [String: Int] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let entries = root["data"] as? [[String: Any]]
        else { return [:] }
        var out: [String: Int] = [:]
        for entry in entries {
            guard
                let id = entry["id"] as? String,
                let contextLength = (entry["context_length"] as? NSNumber)?.intValue,
                contextLength > 0
            else { continue }
            out[normalize(id)] = contextLength
        }
        return out
    }

    // MARK: - Cache

    private static func loadCache() -> Bool {
        guard
            let data = try? Data(contentsOf: cacheURL),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let fetchedAt = (json["fetchedAt"] as? NSNumber)?.doubleValue,
            let limits = json["limits"] as? [String: Int]
        else { return false }
        if Date().timeIntervalSince1970 - fetchedAt > cacheTTL {
            return false
        }
        overlay.withLock { $0 = limits }
        return true
    }

    private static func writeCache(limits: [String: Int]) {
        let json: [String: Any] = [
            "fetchedAt": Date().timeIntervalSince1970,
            "limits": limits,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: []) else { return }
        let dir = cacheURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Test hook

    /// Test-only: replace the fetched overlay directly (bypasses network/cache).
    static func setOverlayForTests(_ map: [String: Int]) {
        overlay.withLock { $0 = map }
    }
}
