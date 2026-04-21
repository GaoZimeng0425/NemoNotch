import SwiftUI

enum MarkdownRenderer {

    static func render(_ markdown: String) -> Text {
        var result = Text("")
        let lines = markdown.components(separatedBy: "\n")
        var inCodeBlock = false
        var codeBlockContent = ""

        for line in lines {
            if line.hasPrefix("```") {
                if inCodeBlock {
                    result = result + Text(codeBlockContent.trimmingCharacters(in: .newlines))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                    codeBlockContent = ""
                    inCodeBlock = false
                } else {
                    if !codeBlockContent.isEmpty { result = result + Text("\n") }
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBlockContent += (codeBlockContent.isEmpty ? "" : "\n") + line
                continue
            }

            if line.isEmpty { continue }

            if line.hasPrefix("### ") {
                result = result + renderInline(String(line.dropFirst(4)))
                    .font(.system(size: 11, weight: .semibold))
                result = result + Text("\n")
                continue
            }
            if line.hasPrefix("## ") {
                result = result + renderInline(String(line.dropFirst(3)))
                    .font(.system(size: 12, weight: .bold))
                result = result + Text("\n")
                continue
            }
            if line.hasPrefix("# ") {
                result = result + renderInline(String(line.dropFirst(2)))
                    .font(.system(size: 13, weight: .bold))
                result = result + Text("\n")
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result = result + Text("  • ") + renderInline(String(line.dropFirst(2)))
                result = result + Text("\n")
                continue
            }

            if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let prefix = line[match]
                let content = String(line[match.upperBound...])
                result = result + Text("  \(prefix)") + renderInline(content)
                result = result + Text("\n")
                continue
            }

            result = result + renderInline(line)
            result = result + Text("\n")
        }

        return result
    }

    static func renderInline(_ text: String) -> Text {
        var result = Text("")
        let pattern = #"(\\*\\*[^*]+\\*\\*|\\*[^*]+\\*|`[^`]+`)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Text(text)
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        var lastEnd = text.startIndex

        for match in matches {
            let range = Range(match.range, in: text)!

            if lastEnd < range.lowerBound {
                let before = String(text[lastEnd..<range.lowerBound])
                result = result + Text(before)
            }

            let matched = String(text[range])

            if matched.hasPrefix("**") && matched.hasSuffix("**") {
                let content = String(matched.dropFirst(2).dropLast(2))
                result = result + Text(content).bold()
            } else if matched.hasPrefix("*") && matched.hasSuffix("*") {
                let content = String(matched.dropFirst(1).dropLast(1))
                result = result + Text(content).italic()
            } else if matched.hasPrefix("`") && matched.hasSuffix("`") {
                let content = String(matched.dropFirst(1).dropLast(1))
                result = result + Text(content)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.8))
            }

            lastEnd = range.upperBound
        }

        if lastEnd < text.endIndex {
            result = result + Text(String(text[lastEnd...]))
        }

        return result
    }
}
