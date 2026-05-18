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
                    let code = Text(codeBlockContent.trimmingCharacters(in: .newlines))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(NotchTheme.textSecondary)
                    result = Text("\(result)\(code)")
                    codeBlockContent = ""
                    inCodeBlock = false
                } else {
                    if !codeBlockContent.isEmpty { result = Text("\(result)\n") }
                    inCodeBlock = true
                }
                continue
            }

            if inCodeBlock {
                codeBlockContent += (codeBlockContent.isEmpty ? "" : "\n") + line
                continue
            }

            if line.isEmpty {
                result = Text("\(result)\n")
                continue
            }

            if line.hasPrefix("### ") {
                let head = renderInline(String(line.dropFirst(4)))
                    .font(.system(size: 11, weight: .semibold))
                result = Text("\(result)\(head)\n")
                continue
            }
            if line.hasPrefix("## ") {
                let head = renderInline(String(line.dropFirst(3)))
                    .font(.system(size: 12, weight: .bold))
                result = Text("\(result)\(head)\n")
                continue
            }
            if line.hasPrefix("# ") {
                let head = renderInline(String(line.dropFirst(2)))
                    .font(.system(size: 13, weight: .bold))
                result = Text("\(result)\(head)\n")
                continue
            }

            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                let item = renderInline(String(line.dropFirst(2)))
                result = Text("\(result)  • \(item)\n")
                continue
            }

            if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
                let prefix = String(line[match])
                let content = renderInline(String(line[match.upperBound...]))
                result = Text("\(result)  \(prefix)\(content)\n")
                continue
            }

            let inline = renderInline(line)
            result = Text("\(result)\(inline)\n")
        }

        return result
    }

    static func renderInline(_ text: String) -> Text {
        var result = Text("")
        let pattern = #"(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return Text(text)
        }

        let nsRange = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: nsRange)
        var lastEnd = text.startIndex

        for match in matches {
            let range = Range(match.range, in: text)!

            if lastEnd < range.lowerBound {
                let before = String(text[lastEnd ..< range.lowerBound])
                result = Text("\(result)\(before)")
            }

            let matched = String(text[range])

            if matched.hasPrefix("**"), matched.hasSuffix("**") {
                let content = String(matched.dropFirst(2).dropLast(2))
                result = Text("\(result)\(Text(content).bold())")
            } else if matched.hasPrefix("*"), matched.hasSuffix("*") {
                let content = String(matched.dropFirst(1).dropLast(1))
                result = Text("\(result)\(Text(content).italic())")
            } else if matched.hasPrefix("`"), matched.hasSuffix("`") {
                let content = String(matched.dropFirst(1).dropLast(1))
                let code = Text(content)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(NotchTheme.accent.opacity(0.9))
                result = Text("\(result)\(code)")
            }

            lastEnd = range.upperBound
        }

        if lastEnd < text.endIndex {
            let tail = String(text[lastEnd...])
            result = Text("\(result)\(tail)")
        }

        return result
    }
}
