import SwiftUI

struct ChatMessageView: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .tool:
            toolBubble
        case .toolResult:
            toolResultBubble
        case .system:
            systemBubble
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.content)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var assistantBubble: some View {
        HStack(alignment: .top, spacing: 6) {
            Circle()
                .fill(.white.opacity(0.3))
                .frame(width: 5, height: 5)
                .padding(.top, 4)
            MarkdownRenderer.render(message.content)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.85))
            Spacer(minLength: 40)
        }
    }

    private var toolBubble: some View {
        HStack(spacing: 4) {
            Image(systemName: ToolStyle.icon(message.toolName))
                .font(.system(size: 9))
                .foregroundStyle(ToolStyle.color(message.toolName))
            if let tool = message.toolName {
                Text(tool)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ToolStyle.color(tool))
            }
            if let input = message.toolInput {
                Text(String(input.prefix(80)))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(ToolStyle.color(message.toolName).opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var toolResultBubble: some View {
        Text(String(message.content.prefix(200)))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
            .lineLimit(3)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
    }

    private var systemBubble: some View {
        Text(message.content)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.3))
            .italic()
    }
}
