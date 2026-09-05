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
/// 3. Claude family matcher (`opus`/`sonnet`) — Claude ids are versioned/
///    dated (`claude-opus-4-8-20250805`) and OpenRouter keys them with dot
///    versions (`claude-opus-4.8`), so neither an exact nor overlay match is
///    reliable; both families support a 1M window.
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
        if let exact = limits[model] { return exact }
        // 2. OpenRouter catalog overlay (auto-discovered, fills gaps).
        let key = normalize(model)
        if let fetched = overlay.withLock({ $0[key] }) { return fetched }
        // 3. Claude family fallback (dated/dot-versioned ids).
        let lowered = model.lowercased()
        if lowered.contains("opus") || lowered.contains("sonnet") {
            return 1_048_576
        }
        // 4. Default.
        return defaultValue
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
        if Date().timeIntervalSince1970 - fetchedAt > cacheTTL { return false }
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
