import Foundation

/// Any JSON value, decoded as-is — for hook payload fields whose shape is the
/// tool's own (`tool_input`): a Bash command, an Edit's paths, a question
/// list. Re-encodes to a JSON string, and exposes a Foundation object for
/// readers that look inside.
enum JSONValue: Decodable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: JSONValue].self))
        }
    }

    var foundation: Any {
        switch self {
        case let .string(value): value
        case let .number(value): value
        case let .bool(value): value
        case let .array(values): values.map(\.foundation)
        case let .object(values): values.mapValues(\.foundation)
        case .null: NSNull()
        }
    }

    /// Compact JSON text (what `PermissionContext.displayInput` parses).
    var jsonString: String? {
        guard JSONSerialization.isValidJSONObject(foundation),
              let data = try? JSONSerialization.data(withJSONObject: foundation, options: [.sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// The one line a card says about a tool call (evlat's rule): the first of
/// `command`, `file_path`, `pattern`, `url`, `query`, `description` that the
/// input carries, its first non-blank line (a shell `\` continuation read as
/// one line), trimmed and capped; a question's first question otherwise.
enum ToolSubject {
    static let keys = ["command", "file_path", "pattern", "url", "query", "description"]
    static let limit = 200

    static func subject(of input: [String: Any]?) -> String? {
        guard let input else { return nil }
        for key in keys {
            guard let value = input[key] as? String, let line = lines(of: value).first else { continue }
            return capped(line)
        }
        if let questions = input["questions"] as? [[String: Any]],
           let text = questions.first?["question"] as? String,
           let line = lines(of: text).first {
            return capped(line)
        }
        return nil
    }

    private static func lines(of value: String) -> [String] {
        var joined: [String] = []
        var pending = ""
        for raw in value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasSuffix("\\"), !line.hasSuffix("\\\\") {
                pending += (pending.isEmpty ? "" : " ") + line.dropLast().trimmingCharacters(in: .whitespaces)
                continue
            }
            let whole = (pending.isEmpty ? line : pending + (line.isEmpty ? "" : " " + line))
                .trimmingCharacters(in: .whitespaces)
            pending = ""
            if !whole.isEmpty {
                joined.append(whole)
            }
        }
        let tail = pending.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty {
            joined.append(tail)
        }
        return joined
    }

    private static func capped(_ line: String) -> String {
        line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}
